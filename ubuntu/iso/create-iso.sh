#!/bin/bash

# https://www.willhaley.com/blog/custom-debian-live-environment/

set -eu

cd output
rm -rf binary
mkdir -p binary/{live,isolinux,boot/grub/x86_64-efi,EFI/BOOT/}
cp vmlinuz* binary/live/vmlinuz
cp initrd* binary/live/initrd
cp root.squashfs binary/live/filesystem.squashfs
cp /usr/lib/ISOLINUX/isolinux.bin binary/isolinux/
cp /usr/lib/syslinux/modules/bios/menu.c32 binary/isolinux/
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 binary/isolinux/
cp /usr/lib/syslinux/modules/bios/libutil.c32 binary/isolinux/
cat > binary/isolinux/isolinux.cfg <<ISOLINUX_CFG
ui menu.c32
prompt 0
menu title Boot Menu
timeout 300
label live-amd64
        menu label ^Live (amd64)
        menu default
        linux /live/vmlinuz
        append initrd=/live/initrd boot=live console=ttyS0

label live-amd64-failsafe
        menu label ^Live (amd64 failsafe)
        linux /live/vmlinuz
        append initrd=/live/initrd boot=live persistence config memtest noapic noapm nodma nomce nolapic nomodeset nosmp nosplash vga=normal

endtext
ISOLINUX_CFG
cat <<'GRUB_CFG' > "binary/boot/grub/grub.cfg"
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660

insmod all_video
insmod font

set default="0"
set timeout=30

# If X has issues finding screens, experiment with/without nomodeset.

menuentry "Live [EFI/GRUB]" {
    search --no-floppy --set=root --label UBUNTU_LIVE
    linux ($root)/live/vmlinuz boot=live
    initrd ($root)/live/initrd
}

menuentry "Live [EFI/GRUB] (nomodeset)" {
    search --no-floppy --set=root --label UBUNTU_LIVE
    linux ($root)/live/vmlinuz boot=live nomodeset
    initrd ($root)/live/initrd
}
GRUB_CFG
cp binary/boot/grub/grub.cfg binary/EFI/BOOT/
cat <<'GRUB_EMBED_CFG' > grub-embed.cfg
if ! [ -d "$cmdpath" ]; then
    # On some firmware, GRUB has a wrong cmdpath when booted from an optical disc.
    # https://gitlab.archlinux.org/archlinux/archiso/-/issues/183
    if regexp --set=1:isodevice '^(\([^)]+\))\/?[Ee][Ff][Ii]\/[Bb][Oo][Oo][Tt]\/?$' "$cmdpath"; then
        cmdpath="${isodevice}/EFI/BOOT"
    fi
fi
configfile "${cmdpath}/grub.cfg"
GRUB_EMBED_CFG
cp -r /usr/lib/grub/x86_64-efi/* binary/boot/grub/x86_64-efi/
#grub-mkstandalone -O i386-efi \
#    --modules="part_gpt part_msdos fat iso9660" \
#    --locales="" \
#    --themes="" \
#    --fonts="" \
#    --output=binary/EFI/BOOT/BOOTIA32.EFI \
#    "boot/grub/grub.cfg=grub-embed.cfg"

grub-mkstandalone -O x86_64-efi \
    --modules="part_gpt part_msdos fat iso9660" \
    --locales="" \
    --themes="" \
    --fonts="" \
    --output="binary/EFI/BOOT/BOOTx64.EFI" \
    "boot/grub/grub.cfg=grub-embed.cfg"

(cd binary && \
    dd if=/dev/zero of=efiboot.img bs=1M count=20 && \
    mkfs.vfat efiboot.img && \
    mmd -i efiboot.img ::/EFI ::/EFI/BOOT && \
    mcopy -vi efiboot.img \
        "EFI/BOOT/BOOTx64.EFI" \
        "boot/grub/grub.cfg" \
        ::/EFI/BOOT/
)

xorriso \
    -as mkisofs \
    -iso-level 3 \
    -o "ubuntu-live.iso" \
    -full-iso9660-filenames \
    -volid "UBUNTU_LIVE" \
    --mbr-force-bootable -partition_offset 16 \
    -joliet -joliet-long -rational-rock \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-boot \
        isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog isolinux/isolinux.cat \
    -eltorito-alt-boot \
        -e --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B binary/efiboot.img \
    "binary"

#xorriso -as mkisofs -r -J -joliet-long -l -cache-inodes -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -partition_offset 16 -A "Ubuntu Live"  -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -o remaster.iso binary

