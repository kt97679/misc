#!/bin/bash

set -ue -o pipefail

output_dir="$(dirname $(realpath $0))/output"
wait_seconds=180
ssh_config=$output_dir/ssh_config

run_ssh() {
    ssh -F $ssh_config qemu "$@"
}

get_free_port() {
    local port=$((1024 + RANDOM % 8192))
    while : > /dev/tcp/127.0.0.1/$((port++)) ; do : ; done 2>/dev/null
    echo $port
}

kill_qemu() {
    pkill ${1:-} -f "tcp:127.0.0.1:$(grep -oP "Port\s+\K\d+" $ssh_config)-"
}

start() {
    local http_port=$(get_free_port) web_root ssh_port deadline=$((SECONDS + wait_seconds)) qemu_cmd http_hook
    kill_qemu -0 && echo "Already running" && exit
    cd $output_dir
    web_root="http://10.0.2.2:$http_port"
    rm -f ssh-key && ssh-keygen -N '' -t ed25519 -f ssh-key &>/dev/null
    echo "mkdir -p /root/.ssh && echo '$(cat ssh-key.pub)' >> /root/.ssh/authorized_keys" >ssh-key.sh
    http_hook="$(printf "http_hook=$web_root/%s " *.sh)"
    for x in *; do
        url=$web_root/$x
        case $x in
            initrd*) initrd=$url ;;
            vmlinuz*) vmlinuz=$url ;;
            *.squashfs) squashfs=$url ;;
        esac
    done
    printf "%s\n" \
        "#!ipxe" \
        "kernel $vmlinuz dhcp boot=live fetch=$squashfs nomodeset console=ttyS0,115200n8 rootsize=10% $http_hook" \
        "initrd $initrd" \
        "boot" >boot.ipxe
    python3 -m http.server $http_port --bind 127.0.0.1 &> http.log &
    trap "kill $!" EXIT
    ssh_port=$(get_free_port)
    printf "%s\n" \
        "Host qemu" \
        "  HostName 127.0.0.1" \
        "  User root" \
        "  Port $ssh_port" \
        "  IdentityFile $output_dir/ssh-key" \
        "  UserKnownHostsFile /dev/null" \
        "  StrictHostKeyChecking no" \
        "  PasswordAuthentication no" \
        "  LogLevel FATAL" > $ssh_config
    qemu_cmd="qemu-system-x86_64 ${QEMU_OPTS:-} \
        -boot n \
        -device virtio-net-pci,netdev=n1 \
        -netdev user,id=n1,tftp=${output_dir},bootfile=/boot.ipxe,hostfwd=tcp:127.0.0.1:${ssh_port}-:22,domainname=$(hostname -d|grep .||echo unknown) \
        -nographic \
	$([ -r /dev/kvm ] && echo -enable-kvm -cpu max) \
        -m 4096"
    ${console:-false} && {
        eval "$qemu_cmd |& tee qemu.log"
        exit
    }
    eval "$qemu_cmd &> qemu.log &"
    while ((SECONDS < deadline)); do
        run_ssh true &> /dev/null && echo "VM is ready in $SECONDS seconds" && exit
        sleep 5
    done
    echo "VM failed to start"
}

case ${1:-} in
    start) start ;;
    stop) kill_qemu || true ;;
    ssh) shift && run_ssh "$@" ;;
    console) console=true start ;;
    *) echo "Usage: $0 start|stop|ssh|console" ;;
esac
