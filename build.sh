#!/bin/bash

## Configuration section ##

# Constants
GITHUB=https://github.com
DATA=/data

# Build parameters
BUILD=cwt22
KERNEL=6.6
SF_VERSION=v5.12.0
SF_TAG=JH7110_VF2_${KERNEL}_${SF_VERSION}
U_BOOT_PKG_VER=2024.04-1
U_BOOT_PKG_URL=${GITHUB}/cwt-vf2/u-boot-starfive-vf2/releases/download/${U_BOOT_PKG_VER}
U_BOOT_PKG=u-boot-starfive-vf2-${U_BOOT_PKG_VER}-riscv64.pkg.tar.zst
ROOTFS=https://riscv.mirror.pkgbuild.com/images/archriscv-2024-03-30.tar.zst

# Output
IMAGE=${DATA}/ArchLinux-VF2_${KERNEL}_${SF_VERSION}-${BUILD}.img
TARGET=${DATA}/${BUILD}
PKGS=${DATA}/pkgs

# Kernel
KNL_REL=3
KNL_NAME=linux-cwt-${KERNEL}-starfive-vf2
KNL_URL=${GITHUB}/cwt-vf2/linux-cwt-starfive-vf2/releases/download/${BUILD}-${SF_VERSION:1}-${KNL_REL}
KNL_SUFFIX=${BUILD:3}.${SF_VERSION:1}-${KNL_REL}-riscv64.pkg.tar.zst

# GPU
GPU_VER=1.19.6345021
GPU_REL=6
# The GPU binary hasn't changed since the last build, so just use the old one.
#GPU_URL=${GITHUB}/cwt-vf2/img-gpu-vf2/releases/download/${BUILD}-${GPU_VER}-${GPU_REL}
GPU_URL=${GITHUB}/cwt-vf2/img-gpu-vf2/releases/download/cwt19-${GPU_VER}-${GPU_REL}
GPU_PKG=img-gpu-vf2-${GPU_VER}-${GPU_REL}-riscv64.pkg.tar.zst

# Mesa
MESA_VER=22.1.7
MESA_REL=4
MESA_URL=${GITHUB}/cwt-vf2/mesa-pvr-vf2/releases/download/v${MESA_VER}-${MESA_REL}
MESA_PKG=mesa-pvr-vf2-${MESA_VER}-${MESA_REL}-riscv64.pkg.tar.zst

# WiFi and Bluetooth Firmware
BUILDROOT=${DATA}/buildroot
BUILDROOT_GIT=${GITHUB}/starfive-tech/buildroot.git
WIFI_BT_FW_PATH=package/starfive/starfive-firmware

# Wave5 Firmware
WAVE5_FW=https://gitlab.collabora.com/chipsnmedia/linux-firmware/-/raw/cnm/cnm/wave511_dec_fw.bin

# Target packages
PACKAGES="base btrfs-progs chrony clinfo compsize dosfstools mtd-utils networkmanager openssh rng-tools\
          smartmontools sudo terminus-font vi vulkan-tools wireless-regdb zram-generator zstd iptables-nft\
	  linux-firmware apparmor python-notify2 python-psutil"

## End configuration section ##

## Build section ##

# Set locale to POSIX standards-compliant
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Remember current directory as working directory
WORK_DIR=$(pwd)

# Install required tools on the builder box
sudo pacman -S wget arch-install-scripts zstd util-linux btrfs-progs dosfstools git xz --needed --noconfirm

# Set wget options
WGET="wget --progress=bar -c -O"

# Download U-Boot (built with Starfive's OpenSBI)
${WGET} ${DATA}/${U_BOOT_PKG} ${U_BOOT_PKG_URL}/${U_BOOT_PKG}

# Install U-Boot on the builder box, the U-Boot images will be at /usr/share/u-boot-starfive-vf2/
sudo pacman -U ${DATA}/${U_BOOT_PKG} --noconfirm

# Prepare build directory
sudo mkdir -p ${DATA}
sudo chown $(id -u):$(id -g) ${DATA}
mkdir -p ${PKGS}

# Download rootfs
${WGET} ${DATA}/rootfs.tar.zst ${ROOTFS}

# Download -cwt kernel
${WGET} ${PKGS}/${KNL_NAME}-${KNL_SUFFIX} ${KNL_URL}/${KNL_NAME}-${KNL_SUFFIX}
${WGET} ${PKGS}/${KNL_NAME}-headers-${KNL_SUFFIX} ${KNL_URL}/${KNL_NAME}-headers-${KNL_SUFFIX}
${WGET} ${PKGS}/${KNL_NAME}-soft_3rdpart-${KNL_SUFFIX} ${KNL_URL}/${KNL_NAME}-soft_3rdpart-${KNL_SUFFIX}

# Download GPU driver
${WGET} ${PKGS}/${GPU_PKG} ${GPU_URL}/${GPU_PKG}

# Download Mesa
${WGET} ${PKGS}/${MESA_PKG} ${MESA_URL}/${MESA_PKG}

# Download WiFi Firmware
rm -rf ${BUILDROOT}
cd ${DATA}
git clone -n --depth=1 --filter=tree:0 -b ${SF_TAG} ${BUILDROOT_GIT}
cd ${BUILDROOT}
git sparse-checkout set --no-cone ${WIFI_BT_FW_PATH}
git checkout

# Download Wave5 Firmware
cd ${DATA}
${WGET} wave511_dec_fw.bin ${WAVE5_FW}

# Setup disk image
cd ${WORK_DIR}
rm -f ${IMAGE}
fallocate -l 2250M ${IMAGE}
LOOP=$(sudo losetup -f -P --show "${IMAGE}")
sudo sfdisk ${LOOP} < parts.txt

# Dump SPL and U-Boot to the disk
sudo dd if=/usr/share/u-boot-starfive-vf2/u-boot-spl.bin.normal.out of=${LOOP}p1 bs=512
sudo dd if=/usr/share/u-boot-starfive-vf2/u-boot.itb of=${LOOP}p2 bs=512

# Format EFI partition
sudo mkfs.vfat -n EFI ${LOOP}p3

# Format root partition
sudo mkfs.btrfs --csum xxhash -L VF2 ${LOOP}p4

# Setup target mount
sudo mkdir -p ${TARGET}
sudo mount -o discard=async,compress=lzo ${LOOP}p4 ${TARGET}
VOLUMES="@ @home @pkg @log @.snapshots"
for volume in ${VOLUMES}; do
	sudo btrfs subvolume create ${TARGET}/${volume}
done
sudo umount ${TARGET}

# Remount all subvolumes
VOLUMES="@:${TARGET} @home:${TARGET}/home\
         @log:${TARGET}/var/log @.snapshots:${TARGET}/.snapshots"
for volume in ${VOLUMES}; do
	IFS=: read -r subvol mnt <<< ${volume}
	sudo mkdir -p ${mnt}
	sudo mount -o discard=async,compress=lzo,subvol=${subvol} ${LOOP}p4 ${mnt}
done

# Mount packages cache as tmpfs
sudo mkdir -p ${TARGET}/var/cache/pacman/pkg
sudo mount -t tmpfs tmpfs ${TARGET}/var/cache/pacman/pkg

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

# Also copy U-Boot package to target
sudo cp ${DATA}/${U_BOOT_PKG} ${TARGET}/root/pkgs

# Disable microcode hook
sudo install -o root -g root -D -m 644 configs/no-microcode-hook.conf ${TARGET}/etc/mkinitcpio.conf.d/no-microcode-hook.conf

# Update and install packages via arch-chroot
sudo arch-chroot ${TARGET} pacman -Syu --noconfirm
sudo arch-chroot ${TARGET} pacman -S ${PACKAGES} --needed --noconfirm --ask=4
sudo arch-chroot ${TARGET} bash -c "pacman -U /root/pkgs/*.pkg.tar.zst --noconfirm"
sudo arch-chroot ${TARGET} pacman -Sc --noconfirm

# Install WiFi Firmware
sudo install -o root -g root -D -m 644 ${BUILDROOT}/${WIFI_BT_FW_PATH}/ECR6600U-usb-wifi/ECR6600U_transport.bin ${TARGET}/usr/lib/firmware/ECR6600U_transport.bin
sudo install -o root -g root -D -m 644 ${BUILDROOT}/${WIFI_BT_FW_PATH}/aic8800-usb-wifi/aic8800/* -t ${TARGET}/usr/lib/firmware/aic8800
sudo install -o root -g root -D -m 644 ${BUILDROOT}/${WIFI_BT_FW_PATH}/aic8800-usb-wifi/aic8800DC/* -t ${TARGET}/usr/lib/firmware/aic8800DC
sudo install -o root -g root -D -m 644 ${BUILDROOT}/${WIFI_BT_FW_PATH}/ap6256-sdio-wifi/* -t ${TARGET}/usr/lib/firmware
sudo install -o root -g root -D -m 644 ${BUILDROOT}/${WIFI_BT_FW_PATH}/ap6256-sdio-wifi/* -t ${TARGET}/usr/lib/firmware

# Install Bluetooth Firmware
sudo install -o root -g root -D -m 644 ${BUILDROOT}/${WIFI_BT_FW_PATH}/ap6256-bluetooth/BCM4345C5.hcd -t ${TARGET}/usr/lib/firmware
sudo install -o root -g root -D -m 755 ${BUILDROOT}/${WIFI_BT_FW_PATH}/ap6256-bluetooth/S36ap6256-bluetooth -t ${TARGET}/etc/init.d
sudo install -o root -g root -D -m 644 ${BUILDROOT}/${WIFI_BT_FW_PATH}/rtl8852bu-bluetooth/* -t ${TARGET}/usr/lib/firmware

# Install Wave5 Firmware
sudo install -o root -g root -D -m 644 ${DATA}/wave511_dec_fw.bin -t ${TARGET}/usr/lib/firmware

# Install default configs
sudo install -o root -g root -m 644 configs/fstab ${TARGET}/etc/fstab
sudo install -o root -g root -m 644 configs/hostname ${TARGET}/etc/hostname
sudo install -o root -g root -m 644 configs/vconsole.conf ${TARGET}/etc/vconsole.conf
sudo install -o root -g root -m 644 configs/zram-generator.conf ${TARGET}/etc/systemd/zram-generator.conf

# Create user
sudo arch-chroot ${TARGET} groupadd user
sudo arch-chroot ${TARGET} useradd -g user --btrfs-subvolume-home -c "Arch User" -m user
sudo arch-chroot ${TARGET} /bin/bash -c "echo 'user:user' | chpasswd -c SHA512"
sudo arch-chroot ${TARGET} /bin/bash -c "echo 'user ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/user"

# Enable services
SERVICES="NetworkManager chronyd rngd smartd sshd apparmor"
for service in ${SERVICES}; do
	sudo arch-chroot ${TARGET} systemctl enable ${service}
done

## End build section ##

## Clean up ##
echo -e "\nTo clean up run: ./cleanup.sh ${TARGET} ${LOOP}"

