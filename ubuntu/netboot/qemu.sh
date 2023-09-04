#!/bin/bash

set -ue

output_dir="$(dirname $(readlink -f $0))/output"
wait_seconds=120
ssh_config=$output_dir/ssh_config

run_ssh() {
    ssh -F $ssh_config qemu "$@"
}

get_free_port() {
    local port
    while true; do
        port=$((1024 + RANDOM % 8192))
        netstat -lnt|grep -q ":${port}\b" && continue
        echo $port
        return
    done
}

kill_pids() {
    local pids=$(cat $output_dir/*.pid 2>/dev/null)
    [ -n "$pids" ] && kill ${1:-} $pids >/dev/null 2>&1
}

start() {
    kill_pids -0 && echo "Already running" && exit
    cd $output_dir
    http_port=$(get_free_port)
    web_root="http://10.0.2.2:$http_port"
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
        "kernel $vmlinuz dhcp boot=live fetch=$squashfs nomodeset console=ttyS0,115200n8 rootsize=10%" \
        "initrd $initrd" \
        "boot" >boot.ipxe
    python3 -m http.server $http_port >http.log 2>&1 &
    echo $! >http.pid
    domainname="$(hostname -d)"
    [ -z "$domainname" ] && domainname="unknown"
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
    qemu-system-x86_64 ${QEMU_OPTS:-} \
        -boot n \
        -device virtio-net-pci,netdev=n1 \
        -netdev user,id=n1,tftp=${output_dir},bootfile=/boot.ipxe,hostfwd=tcp::${ssh_port}-:22,domainname=${domainname} \
        -nographic \
        -m 4096 >qemu.log 2>&1 &
#        -enable-kvm \
#        -cpu max >qemu.log 2>&1 &
    echo $! >qemu.pid
    deadline=$((SECONDS + wait_seconds))
    while ((SECONDS < deadline)); do
        run_ssh true >/dev/null 2>&1 && echo "VM is ready" && exit
        sleep 5
    done
    echo "VM failed to start"
}

case ${1:-} in
    start) start ;;
    stop) kill_pids || true ;;
    ssh) run_ssh ;;
    *) echo "Usage: $0 start|stop|ssh" ;;
esac
