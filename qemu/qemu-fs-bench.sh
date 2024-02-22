#!/bin/bash

/usr/bin/qemu-system-x86_64 \
   -machine pc,accel=kvm,usb=off,dump-guest-core=off -m 2048 \
   -smp 4,sockets=4,cores=1,threads=1 -rtc base=utc \
   -boot strict=on -kernel ./vm/boot/vmlinuz \
   -initrd ./vm/boot/initrd.img \
   -append 'root=fsRoot rw rootfstype=9p rootflags=trans=virtio,version=9p2000.L,msize=5000000,cache=mmap,posixacl console=ttyS0' \
   -fsdev local,security_model=passthrough,multidevs=remap,id=fsdev-fsRoot,path=./vm/ \
   -device virtio-9p-pci,id=fsRoot,fsdev=fsdev-fsRoot,mount_tag=fsRoot \
   -fsdev local,security_model=mapped-xattr,multidevs=remap,id=fsdev-fsRoot2,path=./vm2/ \
   -device virtio-9p-pci,id=fsRoot2,fsdev=fsdev-fsRoot2,mount_tag=fsRoot2 \
   -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
   -device virtio-scsi-pci,id=scsi0 \
   -drive file=myimage.qcow2,if=none,id=disk0,cache=writeback,discard=unmap,format=qcow2 \
   -device scsi-hd,drive=disk0,bus=scsi0.0 \
   -device virtio-net-pci,netdev=n1 \
   -netdev user,id=n1,hostfwd=tcp:127.0.0.1:2222-:22,domainname=$(hostname -d|grep .||echo unknown) \
   -nographic
