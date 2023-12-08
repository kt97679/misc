#!/bin/bash
set -xeu -o pipefail

UBUNTU_VERSION=${1:-22.04}
IMAGE_ROOT="/new_root"
BUILD_DIR="/build"

SCRIPT_DIR=$(dirname $(realpath $0))
OUTPUT_DIR="$SCRIPT_DIR/output"

[ -r /.dockerenv ] || {
    mkdir -p $OUTPUT_DIR
    exec &> >(tee $OUTPUT_DIR/$(basename $0).log)
    exec docker run -u root --entrypoint=$BUILD_DIR/$(basename $0) --rm -v $SCRIPT_DIR:$BUILD_DIR public.ecr.aws/lts/ubuntu:$UBUNTU_VERSION
}

mkdir -p "$IMAGE_ROOT" && cd "$IMAGE_ROOT"

. /etc/os-release
apt-get update && apt-get install --no-install-recommends -y squashfs-tools debootstrap
debootstrap --arch amd64 --variant=minbase --components=main,restricted,universe --include=live-boot,systemd-sysv,openssh-server,linux-image-virtual ${UBUNTU_CODENAME} .
cp /etc/apt/sources.list ./etc/apt/sources.list

sed -i -e '/^PermitRootLogin/d' -e '$aPermitRootLogin without-password' ./etc/ssh/sshd_config
> ./etc/machine-id
./usr/bin/ssh-keygen -N '' -f ./boot/ssh-key
mkdir -p ./root/.ssh && mv ./boot/ssh-key.pub ./root/.ssh/authorized_keys
#echo "root:root"|chpasswd --root $PWD

rm -rf ./var/cache/apt ./etc/{hostname,hosts} ./var/log/*.log ./root/.cache
mksquashfs . ./boot/root.squashfs -b 1048576 -comp xz -Xdict-size 100% -regex -e "proc/.*" -e "sys/.*" -e "run/.*" -e "var/lib/apt/lists/.*" -e "boot/.*"
cd ./boot && chmod -R +r .
setpriv $(stat -c "--reuid=%u --regid=%g" $0) --clear-groups cp ssh-key root.squashfs {vmlinuz,initrd}*generic $OUTPUT_DIR
