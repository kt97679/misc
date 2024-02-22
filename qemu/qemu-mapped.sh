#!/bin/bash

/usr/bin/qemu-system-x86_64 \
   -machine pc,accel=kvm,usb=off,dump-guest-core=off -m 2048 \
   -smp 4,sockets=4,cores=1,threads=1 -rtc base=utc \
   -boot strict=on -kernel $(ls ./vm2/root/boot/vmlinuz-*|sed '$!d') \
   -initrd $(ls ./vm2/root/boot/initrd.img-*|sed '$!d') \
   -append 'root=fsRoot2 rw rootfstype=9p rootflags=trans=virtio,version=9p2000.L,msize=5000000,cache=mmap,posixacl console=ttyS0' \
   -fsdev local,security_model=mapped-xattr,multidevs=remap,id=fsdev-fsRoot2,path=./vm2/root \
   -device virtio-9p-pci,id=fsRoot2,fsdev=fsdev-fsRoot2,mount_tag=fsRoot2 \
   -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
   -device virtio-net-pci,netdev=n1 \
   -netdev user,id=n1,hostfwd=tcp:127.0.0.1:2222-:22,domainname=$(hostname -d|grep .||echo unknown) \
   -nographic
