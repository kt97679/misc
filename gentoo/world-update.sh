#!/bin/bash

set -ue

((UID != 0)) && exec sudo $0

exec &> >(tee /tmp/$(basename $0).log)

cpu_cores="$(grep -c ^processor /proc/cpuinfo)"

#until emerge --sync ; do sleep 10; done
emerge --jobs=$cpu_cores -uDNav world
emerge --jobs=$cpu_cores @preserved-rebuild
emerge --jobs=$cpu_cores -uDNav --with-bdeps=y @world
emerge --jobs=$cpu_cores --depclean
# remove obsolete files from the /usr/portage/distfiles
eclean-dist --deep

# system update is done now let's check if we need to build new kernel
usr_src_linux_old=$(readlink -f /usr/src/linux)
eselect kernel set 1
usr_src_linux_new=$(readlink -f /usr/src/linux)
[ "$usr_src_linux_old" == "$usr_src_linux_new" ] && exit
# symlink was updated, let's remove old sources (if any) and build new kernel
[ -n "$usr_src_linux_old" ] && rm -rf "$usr_src_linux_old"
cd /usr/src/linux
# current kernel config is used
zcat /proc/config.gz > /usr/src/linux/.config
# if new kernel options were added we use default settings
make olddefconfig && make -j $cpu_cores
make modules_install
ln -f /boot/zImage /boot/zImage.old
cp arch/arm/boot/zImage /boot/zImage.new
mv /boot/zImage.new /boot/zImage
ln -f /boot/tegra124-jetson-tk1.dtb /boot/tegra124-jetson-tk1.dtb.old
cp arch/arm/boot/dts/tegra124-jetson-tk1.dtb /boot/tegra124-jetson-tk1.dtb.new
mv /boot/tegra124-jetson-tk1.dtb.new /boot/tegra124-jetson-tk1.dtb
# removing all modules except for running kernel and installed sources
ls -dt /lib/modules/* | grep -v -e $(uname -r) -e $(readlink /usr/src/linux|cut -f2- -d-) | xargs rm -rf
# if our root is on the emmc - exit
mount | grep -q ^/dev/mmcblk0p1 && exit
# if our root is somewhere else sync to emmc
mount /dev/mmcblk0p1 /mnt
rsync -avp --one-file-system --delete / /mnt/
umount /mnt

