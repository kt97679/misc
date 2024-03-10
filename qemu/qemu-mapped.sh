#!/bin/bash

set -eu

rootfs=$1

[ -d $rootfs ] || {
    echo "Error: $rootfs doesn't exist"
    exit 1
}

/usr/bin/qemu-system-x86_64 \
   -machine pc,accel=kvm,usb=off,dump-guest-core=off -m 8192 \
   -smp 4,sockets=4,cores=1,threads=1 -rtc base=utc \
   -boot strict=on -kernel $(ls $rootfs/boot/vmlinuz-*|sed '$!d') \
   -initrd $(ls $rootfs/boot/initrd.img-*|sed '$!d') \
   -append 'root=fsRoot-xattr rw rootfstype=9p rootflags=trans=virtio,version=9p2000.L,msize=5000000,cache=mmap,posixacl console=ttyS0' \
   -fsdev local,security_model=mapped-xattr,multidevs=remap,id=fsdev-fsRoot-xattr,path=$rootfs \
   -device virtio-9p-pci,id=fsRoot-xattr,fsdev=fsdev-fsRoot-xattr,mount_tag=fsRoot-xattr \
   -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
   -device virtio-net-pci,netdev=n1 \
   -netdev user,id=n1,hostfwd=tcp:127.0.0.1:2222-:22,domainname=$(hostname -d|grep .||echo unknown) \
   -nographic
