#!/bin/bash

TARGET=$1
LOOP=$2

# Clean up
sudo umount ${TARGET}/boot
VOLUMES="@:${TARGET} @home:${TARGET}/home @pkg:${TARGET}/var/cache/pacman/pkg @log:${TARGET}/var/log @snapshots:${TARGET}/.snapshots"
RVOLUMES=$(echo $VOLUMES | xargs -n 1 | tac | xargs)
for volume in ${RVOLUMES}; do
	IFS=: read -r subvol mnt <<< $volume
	sudo umount ${mnt}
done

sudo losetup -d ${LOOP}

