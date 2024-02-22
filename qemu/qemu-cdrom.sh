#!/bin/bash
/usr/bin/qemu-system-x86_64 \
   -machine pc,accel=kvm,usb=off,dump-guest-core=off -m 2048 \
   -smp 4,sockets=4,cores=1,threads=1 -rtc base=utc \
   -boot d -cdrom ubuntu-23.10.1-desktop-amd64.iso \
   -fsdev local,security_model=mapped,id=fsdev-fs0,multidevs=remap,path=./vm2/ \
   -device virtio-9p-pci,id=fs0,fsdev=fsdev-fs0,mount_tag=fs0 \
   -device virtio-net-pci,netdev=n1 \
   -netdev user,id=n1,hostfwd=tcp:127.0.0.1:2222-:22,domainname=$(hostname -d|grep .||echo unknown)
