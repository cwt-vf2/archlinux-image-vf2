#!/bin/bash

## Configuration section ##

# Constants
GITHUB=https://github.com
DATA=/data

# Build parameters
BUILD=cwt14
KERNEL=5.15.2
SF_VERSION=v3.1.5
SF_RELEASE_URL=${GITHUB}/starfive-tech/VisionFive2/releases/download
ROOTFS=https://riscv.mirror.pkgbuild.com/images/archriscv-2023-07-10.tar.zst

# Output
IMAGE=${DATA}/ArchLinux-VF2_${KERNEL}_${SF_VERSION}-${BUILD}.img
TARGET=${DATA}/${BUILD}
PKGS=${DATA}/pkgs

# Kernel
KNL_REL=1
KNL_NAME=linux-cwt-515-starfive-visionfive2
KNL_URL=${GITHUB}/cwt/pkgbuild-linux-cwt-starfive-visionfive2/releases/download/${BUILD}-${SF_VERSION:1}-${KNL_REL}
KNL_SUFFIX=${BUILD:3}.${SF_VERSION:1}-${KNL_REL}-riscv64.pkg.tar.zst

# GPU
GPU_VER=1.19.6345021
GPU_REL=2
GPU_URL=${GITHUB}/cwt/aur-visionfive2-img-gpu/releases/download/${BUILD}-${GPU_VER}-${GPU_REL}
GPU_PKG=visionfive2-img-gpu-${GPU_VER}-${GPU_REL}-riscv64.pkg.tar.zst

# Mesa
MESA_VER=21.2.5
MESA_REL=1
MESA_URL=${GITHUB}/cwt/aur-mesa-pvr-vf2/releases/download/v${MESA_VER}-${MESA_REL}
MESA_PKG=mesa-pvr-vf2-${MESA_VER}-${MESA_REL}-riscv64.pkg.tar.zst

# Target packages
PACKAGES="base btrfs-progs chrony clinfo compsize dosfstools mtd-utils networkmanager openssh rng-tools\
          smartmontools sudo terminus-font vi vulkan-tools wireless-regdb zram-generator zstd"

## End configuration section ##

## Build section ##

# Install required tools on the builder box
sudo pacman -S wget arch-install-scripts zstd util-linux btrfs-progs dosfstools --needed --noconfirm

# Prepare build directory
sudo mkdir -p /data
sudo chown $(id -u):$(id -g) /data
mkdir -p /data/pkgs

# Set wget options
WGET="wget --quiet -c -O"

# Download rootfs, StarFive SPL and U-Boot images
${WGET} ${DATA}/rootfs.tar.zst ${ROOTFS}
${WGET} ${DATA}/u-boot-spl.bin.normal.out ${SF_RELEASE_URL}/VF2_${SF_VERSION}/u-boot-spl.bin.normal.out
${WGET} ${DATA}/visionfive2_fw_payload.img ${SF_RELEASE_URL}/VF2_${SF_VERSION}/visionfive2_fw_payload.img

# Download -cwt kernel
${WGET} ${PKGS}/${KNL_NAME}-${KNL_SUFFIX} ${KNL_URL}/${KNL_NAME}-${KNL_SUFFIX}
${WGET} ${PKGS}/${KNL_NAME}-headers-${KNL_SUFFIX} ${KNL_URL}/${KNL_NAME}-headers-${KNL_SUFFIX}
${WGET} ${PKGS}/${KNL_NAME}-soft_3rdpart-${KNL_SUFFIX} ${KNL_URL}/${KNL_NAME}-soft_3rdpart-${KNL_SUFFIX}

# Download GPU driver
${WGET} ${PKGS}/${GPU_PKG} ${GPU_URL}/${GPU_PKG}

# Download Mesa
${WGET} ${PKGS}/${MESA_PKG} ${MESA_URL}/${MESA_PKG}

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
sudo mount -o discard=async,compress=lzo ${LOOP}p4 ${TARGET}
VOLUMES="@ @home @pkg @log @snapshots"
for volume in ${VOLUMES}; do
	sudo btrfs subvolume create ${TARGET}/${volume}
done
sudo umount ${TARGET}

# Remount all subvolumes
VOLUMES="@:${TARGET} @home:${TARGET}/home @pkg:${TARGET}/var/cache/pacman/pkg\
         @log:${TARGET}/var/log @snapshots:${TARGET}/.snapshots"
for volume in ${VOLUMES}; do
	IFS=: read -r subvol mnt <<< ${volume}
	sudo mkdir -p ${mnt}
	sudo mount -o discard=async,compress=lzo,subvol=${subvol} ${LOOP}p4 ${mnt}
done

# Mount /boot and install StarFive u-boot config
sudo mkdir -p ${TARGET}/boot
sudo mount -o discard ${LOOP}p3 ${TARGET}/boot
sudo mkdir -p ${TARGET}/boot/extlinux
sudo install -o root -g root -m 644 configs/uEnv.txt ${TARGET}/boot/uEnv.txt
sudo install -o root -g root -m 644 configs/extlinux.conf ${TARGET}/boot/extlinux/extlinux.conf

# Extract rootfs to target mount
sudo tar -C ${TARGET} --zstd -xf ${DATA}/rootfs.tar.zst

# Copy kernel and GPU driver packages
sudo mkdir -p ${TARGET}/root/pkgs
sudo cp ${DATA}/pkgs/* ${TARGET}/root/pkgs

# Update and install packages via arch-chroot
sudo arch-chroot ${TARGET} pacman -Syu --noconfirm
sudo arch-chroot ${TARGET} pacman -S ${PACKAGES} --needed --noconfirm
sudo arch-chroot ${TARGET} bash -c "pacman -U /root/pkgs/*.pkg.tar.zst --noconfirm"
sudo arch-chroot ${TARGET} pacman -Scc --noconfirm

# Hotfix https://github.com/cwt/pkgbuild-linux-cwt-starfive-visionfive2/issues/1
sudo arch-chroot ${TARGET} sed -ie "s/ALL_config/#ALL_config/g" /etc/mkinitcpio.d/linux.preset

# Install default configs
sudo install -o root -g root -m 644 configs/fstab ${TARGET}/etc/fstab
sudo install -o root -g root -m 644 configs/hostname ${TARGET}/etc/hostname
sudo install -o root -g root -m 644 configs/vconsole.conf ${TARGET}/etc/vconsole.conf
sudo install -o root -g root -m 644 configs/zram-generator.conf ${TARGET}/etc/systemd/zram-generator.conf

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

## End build section ##

## Clean up ##
echo -e "\nTo clean up run: ./cleanup.sh ${TARGET} ${LOOP}"

