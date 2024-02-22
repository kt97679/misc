#!/bin/bash

set -eux -o pipefail

exec &> >(tee /tmp/$(basename $0).log)

UBUNTU_CODENAME=noble
NEW_ROOT=./vm-${UBUNTU_CODENAME}
NEW_VM_NAME=ubuntu-dev
USERNAME=$SUDO_USER
SSH_PUB="$(cat /home/$USERNAME/.ssh/*.pub)"

rm -rf $NEW_ROOT && mkdir $NEW_ROOT

debootstrap \
    --variant=minbase \
    --components=main,restricted,universe \
    --include=systemd-sysv,openssh-server,linux-image-virtual,initramfs-tools,sudo,systemd-resolved,dbus \
    ${UBUNTU_CODENAME} \
    $NEW_ROOT
mkdir -p $NEW_ROOT/etc/initramfs-tools
cat > $NEW_ROOT/etc/initramfs-tools/modules <<MODULES
9p
9pnet
9pnet_virtio
MODULES

mkdir -p $NEW_ROOT/etc/systemd/network
cat > $NEW_ROOT/etc/systemd/network/80-dhcp.network <<NETWORK
[Match]
Name=en*
[Network]
DHCP=yes
NETWORK

echo 'tmpfs /tmp tmpfs rw,nosuid,nodev,size=524288k,nr_inodes=204800 0 0' >> $NEW_ROOT/etc/fstab

echo "$NEW_VM_NAME" >$NEW_ROOT/etc/hostname
sed -e "s/\(127.0.1.1\).*/\1 $NEW_VM_NAME/" /etc/hosts >$NEW_ROOT/etc/hosts

chroot $NEW_ROOT <<CHROOT
useradd -m -s /bin/bash $USERNAME
usermod -p '*' $USERNAME
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/$USERNAME
chmod 0440 /etc/sudoers.d/$USERNAME
mkdir /home/$USERNAME/.ssh
echo "$SSH_PUB" >/home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME
usermod -a -G adm,cdrom,dip,plugdev,sudo $USERNAME
systemctl enable systemd-networkd.service
update-initramfs -c -k all
CHROOT

rm -rf $NEW_ROOT/{run,dev}/*
