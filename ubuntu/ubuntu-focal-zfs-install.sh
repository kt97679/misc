#!/bin/bash
set -ue

# export DISK1=/dev/disk/by-id/ata-VBOX_HARDDISK_VBad5107ca-df268eef
# export DISK2=/dev/disk/by-id/ata-VBOX_HARDDISK_VBaf134a71-943e2d11
# export HOSTNAME=ubuntu-zfs-vm
# export USERNAME=toor

echo $DISK1 $DISK2 $HOSTNAME $USERNAME

sgdisk --zap-all $DISK1
sgdisk --zap-all $DISK2
sgdisk -n1:1M:+256M -t1:EF00 -c1:EFI $DISK1
sgdisk -n1:1M:+256M -t1:EF00 -c1:EFI $DISK2
sgdisk -n2:0:+1024M -t2:be00 -c2:Boot $DISK1
sgdisk -n2:0:+1024M -t2:be00 -c2:Boot $DISK2
sgdisk -n3:0:0 t3:bf00 -c3:Ubuntu $DISK1
sgdisk -n3:0:0 -t3:bf00 -c3:Ubuntu $DISK2
mkfs.msdos -F 32 -n EFI ${DISK1}-part1
sleep 2
mkfs.msdos -F 32 -n EFI ${DISK2}-part1
zpool create -f -o cachefile=/etc/zfs/zpool.cache -o ashift=12 \
    -o autotrim=on -d -o feature@async_destroy=enabled \
    -o feature@bookmarks=enabled -o feature@embedded_data=enabled \
    -o feature@empty_bpobj=enabled -o feature@enabled_txg=enabled \
    -o feature@extensible_dataset=enabled -o feature@filesystem_limits=enabled \
    -o feature@hole_birth=enabled -o feature@large_blocks=enabled \
    -o feature@lz4_compress=enabled -o feature@spacemap_histogram=enabled \
    -O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off \
    -O normalization=formD -O relatime=on -O xattr=sa -O mountpoint=/boot \
    -R /mnt bpool mirror ${DISK1}-part2 ${DISK2}-part2
zpool create -f -o ashift=12 -o autotrim=on -O encryption=aes-256-gcm \
    -O keylocation=prompt -O keyformat=passphrase -O acltype=posixacl \
    -O canmount=off -O compression=lz4 -O dnodesize=auto \
    -O normalization=formD -O relatime=on -O xattr=sa -O mountpoint=/ \
    -R /mnt rpool mirror ${DISK1}-part3 ${DISK2}-part3
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT
UUID=$(dd if=/dev/urandom bs=1 count=100 2>/dev/null |tr -dc 'a-z0-9' | cut -c-6)
zfs create -o mountpoint=/ -o com.ubuntu.zsys:bootfs=yes \
    -o com.ubuntu.zsys:last-used=$(date +%s) rpool/ROOT/ubuntu_$UUID
zfs create -o mountpoint=/boot bpool/BOOT/ubuntu_$UUID
zfs create -o canmount=off -o mountpoint=/ rpool/USERDATA
zfs create -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/ubuntu_$UUID \
    -o canmount=on -o mountpoint=/home/$USERNAME rpool/USERDATA/${USERNAME}_$UUID
apt-get install -y debootstrap
debootstrap focal /mnt
echo $HOSTNAME >/mnt/etc/hostname 
sed '/cdrom/d' /etc/apt/sources.list > /mnt/etc/apt/sources.list
sed "s/ubuntu/$HOSTNAME/" /etc/hosts > /mnt/etc/hosts
cp /etc/netplan/*.yaml /mnt/etc/netplan/
mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

cat <<'CHROOT' >/mnt/tmp/chroot-install.sh
#!/bin/bash
set -ue
apt-get update
locale-gen --purge "en_US.UTF-8"
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US
dpkg-reconfigure --frontend noninteractive locales
dpkg-reconfigure tzdata
mkdir /run/efi1
mount $DISK1-part1 /run/efi1
ln -s /run/efi1 /boot/efi
echo /dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK1}-part1) /run/efi1 vfat defaults 0 0 >> /etc/fstab
echo /dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK2}-part1) /run/efi2 vfat defaults 0 0 >> /etc/fstab
apt install --yes grub-efi-amd64 grub-efi-amd64-signed linux-image-generic shim-signed zfs-initramfs zsys ubuntu-minimal network-manager
sed -ie 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)/\1 init_on_alloc=0/' /etc/default/grub
zfs create -V 4G -b $(getconf PAGESIZE) -o compression=off -o logbias=throughput -o sync=always -o primarycache=metadata -o secondarycache=none rpool/swap
mkswap -f /dev/zvol/rpool/swap
echo "/dev/zvol/rpool/swap none swap defaults 0 0" >> /etc/fstab
echo RESUME=none > /etc/initramfs-tools/conf.d/resume

adduser $USERNAME
find /etc/skel/ -type f|xargs cp -t /home/$USERNAME
chown -R $USERNAME:$USERNAME /home/$USERNAME
usermod -a -G adm,cdrom,dip,plugdev,sudo $USERNAME

update-initramfs -c -k all
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy
umount /run/efi1
CHROOT
chmod +x /mnt/tmp/chroot-install.sh

chroot /mnt /usr/bin/env DISK1=$DISK1 DISK2=$DISK2 USERNAME=$USERNAME /tmp/chroot-install.sh
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export -a

