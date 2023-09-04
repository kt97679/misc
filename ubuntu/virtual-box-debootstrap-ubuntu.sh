#!/bin/bash

# vbox port forwarding host:2222 -> guest:22
# host: ./this-file
# guest: nc -w1 10.0.2.2 1222 | bash

SSH_PUB="$(cat ~/.ssh/*.pub)"
USERNAME=kvt
DISTRO=jammy
NEW_HOST_NAME=ubuntu-dev

run_nc() {
    (
        declare -p SSH_PUB
        declare -p USERNAME
        declare -p DISTRO
        declare -p NEW_HOST_NAME
        declare -f main
        echo "main"
    ) | nc -l -p 1222
    exit 0
}

main() {
    set -eu

    [ -n "${1:-}" ] && run_nc

    exec &> >(tee /tmp/install.log)

    sgdisk --zap-all /dev/sda
    sgdisk -n 0:0:+1MiB -t 0:ef02 -c 0:grub /dev/sda
    sgdisk -n 0:0:0 -t 0:8300 -c 0:root /dev/sda
    mkfs.ext4 /dev/sda2
    tune2fs -O "^orphan_file,^metadata_csum_seed" /dev/sda2
    mount /dev/sda2 /mnt
    apt-get update && apt-get install -y debootstrap
    debootstrap --arch amd64 --variant=minbase jammy /mnt/
    . /etc/os-release 
    grep "^deb h" /etc/apt/sources.list|sed -e "s/$UBUNTU_CODENAME/jammy/" >/mnt/etc/apt/sources.list
    mount --make-private --rbind /dev  /mnt/dev
    mount --make-private --rbind /proc /mnt/proc
    mount --make-private --rbind /sys  /mnt/sys
    echo "$NEW_HOST_NAME" >/mnt/etc/hostname
    sed -e "s/\(127.0.1.1\).*/\1 $NEW_HOST_NAME/" /etc/hosts >/mnt/etc/hosts
    cat >/mnt/etc/fstab <<FSTAB
/dev/sda2 / ext4 errors=remount-ro 0 1
tmpfs /tmp tmpfs nosuid,nodev 0 0
FSTAB
    chroot /mnt /bin/bash <<CHROOT
        apt-get update
        apt-get install -y --no-install-recommends grub2 linux-image-generic openssh-server systemd-sysv initramfs-tools sudo
        cat > /etc/systemd/network/80-dhcp.network <<NETWORK
[Match]
Name=en*
[Network]
DHCP=yes
NETWORK
        systemctl enable systemd-networkd.service
        useradd -m -s /bin/bash $USERNAME
        usermod -p '*' $USERNAME
        echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/$USERNAME
        chmod 0440 /etc/sudoers.d/$USERNAME
        mkdir /home/$USERNAME/.ssh
        echo "$SSH_PUB" >/home/$USERNAME/.ssh/authorized_keys
        chown -R $USERNAME:$USERNAME /home/$USERNAME
        usermod -a -G adm,cdrom,dip,plugdev,sudo $USERNAME
        update-initramfs -c -k all
        update-grub
        grub-install /dev/sda
CHROOT
}

main local
