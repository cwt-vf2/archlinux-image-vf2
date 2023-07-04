#!/bin/bash

BUILD=cwt14
KERNEL=5.15.2
SF_VERSION=v3.1.5
SF_RELEASE_URL=https://github.com/starfive-tech/VisionFive2/releases/download

ROOTFS=https://riscv.mirror.pkgbuild.com/images/archriscv-2023-06-07.tar.zst

DATA=/data
IMAGE=${DATA}/ArchLinux-VF2_${KERNEL}_${SF_VERSION}-${BUILD}.img
TARGET=${DATA}/${BUILD}

WGET="wget --quiet -c -O"

# Install required tools
sudo pacman -S wget arch-install-scripts zstd util-linux btrfs-progs dosfstools --needed --noconfirm

# Prepare build directories
sudo mkdir -p /data
sudo chown $(id -u):$(id -g) /data
mkdir -p /data/pkgs

# Download rootfs, StarFive SPL and U-Boot images
${WGET} ${DATA}/rootfs.tar.zst ${ROOTFS}
${WGET} ${DATA}/u-boot-spl.bin.normal.out ${SF_RELEASE_URL}/VF2_${SF_VERSION}/u-boot-spl.bin.normal.out
${WGET} ${DATA}/visionfive2_fw_payload.img ${SF_RELEASE_URL}/VF2_${SF_VERSION}/visionfive2_fw_payload.img

# Download -cwt kernel and GPU driver
KNL_REL=1
KNL_NAME=linux-cwt-515-starfive-visionfive2
KNL_URL=https://github.com/cwt/pkgbuild-linux-cwt-starfive-visionfive2/releases/download/${BUILD}-${SF_VERSION:1}-${KNL_REL}
GPU_VER=1.19.6345021
GPU_REL=2
GPU_URL=https://github.com/cwt/aur-visionfive2-img-gpu/releases/download/${BUILD}-${GPU_VER}-${GPU_REL}/visionfive2-img-gpu-${GPU_VER}-${GPU_REL}-riscv64.pkg.tar.zst
${WGET} ${DATA}/pkgs/${KNL_NAME}-${BUILD:3}.${SF_VERSION:1}-${KNL_REL}-riscv64.pkg.tar.zst ${KNL_URL}/${KNL_NAME}-${BUILD:3}.${SF_VERSION:1}-${KNL_REL}-riscv64.pkg.tar.zst
${WGET} ${DATA}/pkgs/${KNL_NAME}-headers-${BUILD:3}.${SF_VERSION:1}-${KNL_REL}-riscv64.pkg.tar.zst ${KNL_URL}/${KNL_NAME}-headers-${BUILD:3}.${SF_VERSION:1}-${KNL_REL}-riscv64.pkg.tar.zst
${WGET} ${DATA}/pkgs/${KNL_NAME}-soft_3rdpart-${BUILD:3}.${SF_VERSION:1}-${KNL_REL}-riscv64.pkg.tar.zst ${KNL_URL}/${KNL_NAME}-soft_3rdpart-${BUILD:3}.${SF_VERSION:1}-${KNL_REL}-riscv64.pkg.tar.zst
${WGET} ${DATA}/pkgs/visionfive2-img-gpu-${GPU_VER}-${GPU_REL}-riscv64.pkg.tar.zst ${GPU_URL}

# Setup disk image
rm -f ${IMAGE}
fallocate -l 2250M ${IMAGE}
LOOP=$(sudo losetup -f -P --show "${IMAGE}")
sudo sfdisk ${LOOP} < parts.txt

# Dump SPL and U-Boot to the disk
sudo dd if=${DATA}/u-boot-spl.bin.normal.out of=${LOOP}p1 bs=4096 oflag=direct
sudo dd if=${DATA}/visionfive2_fw_payload.img of=${LOOP}p2 bs=4096 oflag=direct

# Format EFI partition
sudo mkfs.vfat -n EFI ${LOOP}p3

# Format root partition
sudo mkfs.btrfs --csum xxhash -L VF2 ${LOOP}p4

# Setup target mount
sudo mkdir -p ${TARGET}
sudo mount -o discard=async,compress=lzo,user_subvol_rm_allowed ${LOOP}p4 ${TARGET}
sudo btrfs subvolume create ${TARGET}/@
sudo btrfs subvolume create ${TARGET}/@home
sudo btrfs subvolume create ${TARGET}/@pkg
sudo btrfs subvolume create ${TARGET}/@log
sudo btrfs subvolume create ${TARGET}/@snapshots
sudo umount ${TARGET}

# Remount all subvolumes
VOLUMES="@:${TARGET} @home:${TARGET}/home @pkg:${TARGET}/var/cache/pacman/pkg @log:${TARGET}/var/log @snapshots:${TARGET}/.snapshots"
for volume in ${VOLUMES}; do
	IFS=: read -r subvol mnt <<< $volume
	sudo mkdir -p ${mnt}
	sudo mount -o discard=async,compress=lzo,user_subvol_rm_allowed,subvol=${subvol} ${LOOP}p4 ${mnt}
done

# Mount /boot and install StarFive u-boot config
sudo mkdir -p ${TARGET}/boot
sudo mount -o discard ${LOOP}p3 ${TARGET}/boot
sudo mkdir -p ${TARGET}/boot/extlinux
sudo install -o root -g root -m 644 uEnv.txt ${TARGET}/boot/uEnv.txt
sudo install -o root -g root -m 644 extlinux.conf ${TARGET}/boot/extlinux/extlinux.conf

# Extract rootfs to target mount
sudo tar -C ${TARGET} --zstd -xf ${DATA}/rootfs.tar.zst

# Copy kernel and GPU driver packages
sudo mkdir -p ${TARGET}/root/pkgs
sudo cp ${DATA}/pkgs/* ${TARGET}/root/pkgs

# Update and install packages via arch-chroot
PACKAGES="base btrfs-progs chrony compsize dosfstools mtd-utils networkmanager openssh rng-tools smartmontools sudo terminus-font vi wireless-regdb zram-generator zstd"
sudo arch-chroot ${TARGET} pacman -Syu --noconfirm
sudo arch-chroot ${TARGET} pacman -S ${PACKAGES} --needed --noconfirm
sudo arch-chroot ${TARGET} bash -c "pacman -U /root/pkgs/*.pkg.tar.zst --noconfirm"
sudo arch-chroot ${TARGET} pacman -Scc --noconfirm

# Install default config
sudo install -o root -g root -m 644 fstab ${TARGET}/etc/fstab
sudo install -o root -g root -m 644 hostname ${TARGET}/etc/hostname
sudo install -o root -g root -m 644 vconsole.conf ${TARGET}/etc/vconsole.conf
sudo install -o root -g root -m 644 zram-generator.conf ${TARGET}/etc/systemd/zram-generator.conf

# Create user
sudo arch-chroot ${TARGET} groupadd user
sudo arch-chroot ${TARGET} useradd -g user --btrfs-subvolume-home -c "Arch User" -m user
sudo arch-chroot ${TARGET} /bin/bash -c "echo 'user:user' | chpasswd"
sudo arch-chroot ${TARGET} /bin/bash -c "echo 'user ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/user"

# Enable services
SERVICES="NetworkManager chronyd rngd smartd sshd"
for service in ${SERVICES}; do
	sudo arch-chroot ${TARGET} systemctl enable ${service}
done

# Show files
#sudo find ${TARGET}

# Clean up

echo "To clean up run: ./cleanup.sh ${TARGET} ${LOOP}"

