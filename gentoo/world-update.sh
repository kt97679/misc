#!/bin/bash

set -ue

[ "$(id -u)" != "0" ] && {
    sudo $0 || true
    exit
}

exec &> >(tee /tmp/$(basename $0).log)

#until emerge --sync ; do sleep 10; done
emerge -uDNav world
emerge @preserved-rebuild
emerge -uDNav --with-bdeps=y @world
emerge --depclean
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
make olddefconfig && make
mv /boot/zImage /boot/zImage.old
cp arch/arm/boot/zImage /boot/
cp arch/arm/boot/dts/tegra124-jetson-tk1.dtb /boot
make modules_install
# if our root is on the emmc - exit
mount | grep -q ^/dev/mmcblk0p1 && exit
# if our root is somewhere else sync to emmc
mount /dev/mmcblk0p1 /mnt
rsync -avp --one-file-system --delete / /mnt/
umount /mnt

