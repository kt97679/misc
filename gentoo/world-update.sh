#!/bin/bash

set -ue

# eMMC partition the system is copied to (find it with: blkid /dev/mmcblk*p1)
emmc=UUID=put-the-emmc-uuid-here

((UID == 0)) || exec sudo "$0" "$@"

exec &> >(tee "/var/log/$(basename "$0").log")

#until emerge --sync ; do sleep 10; done
emerge -uDNav @world
emerge @preserved-rebuild
emerge -a --depclean
# remove obsolete files from the distfiles directory
eclean-dist --deep

# point /usr/src/linux at the newest sources and delete the older trees
eselect kernel set "$(eselect kernel list | grep -c '^ *\[')"
for d in /usr/src/linux-*; do [ "$d" -ef /usr/src/linux ] || rm -rf "$d"; done
release=$(readlink /usr/src/linux | cut -f2- -d-)
# nothing to do if this kernel was already built and installed
[ -d "/lib/modules/$release" ] && exit
cd /usr/src/linux
# current kernel config is used, new options get their default settings
zcat /proc/config.gz > .config
make olddefconfig
make -j "$(nproc)"
ln -f /boot/zImage /boot/zImage.old
cp arch/arm/boot/zImage /boot/zImage.new
mv /boot/zImage.new /boot/zImage
ln -f /boot/tegra124-jetson-tk1.dtb /boot/tegra124-jetson-tk1.dtb.old
cp arch/arm/boot/dts/nvidia/tegra124-jetson-tk1.dtb /boot/tegra124-jetson-tk1.dtb.new
mv /boot/tegra124-jetson-tk1.dtb.new /boot/tegra124-jetson-tk1.dtb
# installed last, so /lib/modules/$release only exists after a complete install
make INSTALL_MOD_STRIP=1 modules_install
# removing all modules except for the running kernel and the new one
ls -d /lib/modules/* | grep -v -e "$(uname -r)" -e "$release" | xargs rm -rf
# if our root is on the emmc - exit
case $(findmnt -no SOURCE /) in /dev/mmcblk*) exit ;; esac
# if our root is somewhere else sync to emmc
mount "$emmc" /mnt
rsync -aHAXv --one-file-system --delete / /mnt/
umount /mnt
