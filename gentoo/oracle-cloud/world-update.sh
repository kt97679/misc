#!/bin/bash

set -ue

((UID != 0)) && exec sudo -E $0

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
grep -q "BOOT_IMAGE=[^ ]*[.]prev" /proc/cmdline || {
    rm -f /boot/*.prev
    for file in /boot/*-$(uname -r); do
        [ -f "$file" ] && cp $file ${file}.prev
    done
}
make install
rm -f /boot/*.old
printf "%s\n" > /boot/grub/grub.cfg.new \
    "serial --unit=0 --speed=115200" \
    "terminal_input serial" \
    "terminal_output serial" \
    "set timeout=5"
for file in $(ls -t /boot/vmlinuz-*|grep -v "$(uname -r)$"); do
    printf "%s\n" \
        "menuentry '$file' {" \
        "  linux $file root=/dev/sda1 console=tty1 console=ttyS0 nvme.shutdown_timeout=10 libiscsi.debug_libiscsi_eh=1" \
        "}"
done >> /boot/grub/grub.cfg.new
cp /boot/grub/grub.cfg /boot/grub/grub.cfg.prev
mv /boot/grub/grub.cfg.new /boot/grub/grub.cfg
rm -f /boot/*-$(uname -r)
