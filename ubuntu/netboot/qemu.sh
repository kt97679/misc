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

kill_pids() {
    cat $output_dir/*.pid 2>/dev/null | xargs -r kill ${1:-} 2>/dev/null
}

start() {
    local console=false cmd_suffix=">qemu.log 2>&1 &" http_port=$(get_free_port) web_root ssh_port deadline=$((SECONDS + wait_seconds))
    kill_pids -0 && echo "Already running" && exit
    [ "${1:-}" == "console" ] && console=true
    cd $output_dir
    python3 -m http.server $http_port --bind 127.0.0.1 >http.log 2>&1 &
    echo $! >http.pid
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
    ssh_port=$(get_free_port)
    chmod 0600 ssh-key
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
    $console && cmd_suffix=""
    eval qemu-system-x86_64 ${QEMU_OPTS:-} \
        -boot n \
        -device virtio-net-pci,netdev=n1 \
        -netdev user,id=n1,tftp=${output_dir},bootfile=/boot.ipxe,hostfwd=tcp:127.0.0.1:${ssh_port}-:22,domainname=$(hostname -d|grep .||echo unknown) \
        -nographic \
	$([ -r /dev/kvm ] && echo -enable-kvm -cpu max) \
        -m 4096 "$cmd_suffix"
    echo $! >qemu.pid
    while ((SECONDS < deadline)); do
        run_ssh true >/dev/null 2>&1 && echo "VM is ready in $SECONDS seconds" && exit
        sleep 5
    done
    echo "VM failed to start"
}

case ${1:-} in
    start) start ;;
    stop) kill_pids || true ;;
    ssh) shift && run_ssh "$@" ;;
    console) start console ;;
    *) echo "Usage: $0 start|stop|ssh|console" ;;
esac
