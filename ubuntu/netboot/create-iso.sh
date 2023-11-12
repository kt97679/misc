#!/bin/bash

set -eu

cd output
rm -rf binary
mkdir -p binary/{live,isolinux}
cp vmlinuz* binary/live/vmlinuz
cp initrd* binary/live/initrd
cp root.squashfs binary/live/filesystem.squashfs
cp /usr/lib/ISOLINUX/isolinux.bin binary/isolinux/
cp /usr/lib/syslinux/modules/bios/menu.c32 binary/isolinux/
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 binary/isolinux/
cp /usr/lib/syslinux/modules/bios/libutil.c32 binary/isolinux/
cat > binary/isolinux/isolinux.cfg <<MENU
ui menu.c32
prompt 0
menu title Boot Menu
timeout 300
label live-amd64
        menu label ^Live (amd64)
        menu default
        linux /live/vmlinuz
        append initrd=/live/initrd boot=live persistence quiet

label live-amd64-failsafe
        menu label ^Live (amd64 failsafe)
        linux /live/vmlinuz
        append initrd=/live/initrd boot=live persistence config memtest noapic noapm nodma nomce nolapic nomodeset nosmp nosplash vga=normal

endtext
MENU
xorriso -as mkisofs -r -J -joliet-long -l -cache-inodes -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -partition_offset 16 -A "Ubuntu Live"  -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -o remaster.iso binary

