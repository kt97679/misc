#!/bin/bash
set -xeu

UBUNTU_VERSION=${1:-22.04}
IMAGE_ROOT="/new_root"

SCRIPT_DIR=$(dirname $(realpath $0))

[ -z "${PACKER_BUILD_NAME:-}" ] && {
    exec packer build -var IMAGE="public.ecr.aws/lts/ubuntu:$UBUNTU_VERSION" build.json
}

at_exit() {
    chown -R --reference=$0 $SCRIPT_DIR
}

trap at_exit EXIT

mkdir -p /build/output
mkdir -p "$IMAGE_ROOT"

. /etc/os-release
apt-get update && apt-get install --no-install-recommends -y squashfs-tools debootstrap
debootstrap --arch amd64 --variant=minbase ${UBUNTU_CODENAME} ${IMAGE_ROOT}
cp /etc/apt/sources.list ${IMAGE_ROOT}/etc/apt/sources.list

pseudo_fs=(
    "dev     devtmpfs                   devtmpfs"
    "dev/pts devpts   -o gid=5,mode=620 devpts"
    "proc    proc                       proc"
    "run     tmpfs    -o mode=755       tmpfs"
    "sys     sysfs                      sysfs"
    "tmp     tmpfs                      tmpfs"
    "var/tmp tmpfs                      tmpfs"
)

clear_mount_point() {
    find ${IMAGE_ROOT}/$1 -mindepth 1 -print0 | xargs -0 --no-run-if-empty rm -rf
}

printf "%s\n" "${pseudo_fs[@]}"|while read mount_point mount_options; do
    clear_mount_point $mount_point
    mount -t $mount_options ${IMAGE_ROOT}/$mount_point
done
chmod 1777 "${IMAGE_ROOT}/dev/shm"

chroot ${IMAGE_ROOT} /bin/bash <<CHROOT
apt-get update
apt-get install --no-install-recommends -y live-boot systemd-sysv openssh-server linux-image-virtual
apt-get dist-upgrade -y
apt-get autoremove --purge -y
apt-get clean
sed -i -e '/^PermitRootLogin/d' /etc/ssh/sshd_config
echo -e "\nPermitRootLogin without-password" >>/etc/ssh/sshd_config
rm -rf /etc/{hostname,hosts} /var/log/*.log /root/.cache
> /etc/machine-id
mkdir -p /root/.ssh && ssh-keygen -N '' -f /root/.ssh/ssh-key
mv /root/.ssh/ssh-key.pub /root/.ssh/authorized_keys
CHROOT

printf "%s\n" "${pseudo_fs[@]}"|tac|while read mount_point mount_options; do
    umount ${IMAGE_ROOT}/${mount_point}
    clear_mount_point $mount_point
done

mv ${IMAGE_ROOT}/root/.ssh/ssh-key /build/output/
cp ${IMAGE_ROOT}/boot/{vmlinuz,initrd}*generic /build/output/
rm -f /build/output/root.squashfs
mksquashfs ${IMAGE_ROOT} /build/output/root.squashfs -b 1048576 -comp xz -Xdict-size 100% -regex -e proc/.* -e sys/.* -e run/.* -e var/lib/apt/lists/.* -e boot/.*
