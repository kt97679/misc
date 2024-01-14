#!/bin/bash

set -ue

HOST=${1:-$(hostname -s)}

((UID != 0)) && exec sudo -E $0 $HOST

exec &> >(tee /tmp/$(basename $0).log)

# interval_label interval_duration_in_seconds interval_backup_count
CONFIG=(
    "hourly 3600 168"
    "daily 86400 180"
    "weekly 604800 104"
    "monthly 2419200 52"
)
MIN_BACKUP_COUNT=24
MIN_FREE_SPACE=$((1 * 1024 * 1024))
MIN_FREE_INODES=1000
WORK_DIR=$(dirname $(readlink -f $0))

[[ "$WORK_DIR" =~ backup ]] || {
    echo "Error: WORK_DIR \"$WORK_DIR\" doesn't match \"backup\""
    exit
}

get_lock() {
    local pid PID_LIST=$1
    while true; do
        while read pid; do
            kill -0 $pid || continue
            [ "$pid" != "$BASHPID" ] && return 1
            echo $BASHPID >$PID_LIST.new && mv $PID_LIST.new $PID_LIST && return 0
        done < $PID_LIST
        echo $BASHPID >>$PID_LIST
    done 2>/dev/null
}

rsync_options=""
remote_host=""
[ $HOST != $(hostname -s) ] && {
    rsync_options="-e ssh"
    remote_host="${SUDO_USER}@${HOST}:"
}

[ -d ${WORK_DIR}/${HOST} ] || {
    echo "Error: directory ${WORK_DIR}/${HOST} doesn't exist"
    exit
}

get_lock /tmp/$(basename $0).$HOST.pid || {
    echo "Error: another backup for $HOST is in progress"
    exit
}

[ -f ${WORK_DIR}/${HOST}/.config ] && . ${WORK_DIR}/${HOST}/.config
latest=${WORK_DIR}/${HOST}/latest/
previous=$(ls -dt ${WORK_DIR}/${HOST}/* | grep -v "/latest$" | head -n1)
[ -n "$previous" ] && rsync_options+=" --link-dest=$previous"

cleanup_backups() {
    local label label_count dir_to_delete
    read label_count label < <(ls ${WORK_DIR}/${HOST}/ | cut -f3 -d_ | sort | uniq -c | sort -rn | head -n1)
    ((label_count < MIN_BACKUP_COUNT)) && {
        echo "Error: found $label_count backups with label \"$label\", need to keep at least $MIN_BACKUP_COUNT"
        exit 1
    }
    dir_to_delete=$(ls -dt ${WORK_DIR}/${HOST}/* | grep -P "/[^/]*_?${label}$" | tail -n1)
    echo "Cleanup: $dir_to_delete"
    nice rm -rf "$dir_to_delete"
}

while true; do
    nice rsync -av --ignore-errors --rsync-path='sudo rsync' $rsync_options ${remote_host}{/home,/etc} $latest || :
    read avail iavail < <(df --output=avail,iavail $WORK_DIR|sed 1d)
    ((avail > MIN_FREE_SPACE && iavail > MIN_FREE_INODES)) && break
    cleanup_backups
done

get_interval_label_and_count() {
    local label label_count label_duration timestamp now=$(date +%s) dir_name output
    while read label label_duration label_count; do
        # we need to prepare output here since outside of the loop label and label_count will be empty
        output="$label $label_count"
        dir_name=$(ls -dt ${WORK_DIR}/${HOST}/*_${label} 2>/dev/null | head -n1)
        timestamp=0
        [ -n "$dir_name" ] && timestamp=$(date -d "$(basename $dir_name | sed -e 's/_[^_]*$//' -e 's/_/ /')" +%s)
        ((now - timestamp > $label_duration)) && break
    done < <(printf "%s\n" "${CONFIG[@]}" | grep -P "^\S+\s+\d+\s+\d+$" | sort -rn -k2)
    # with grep in the previous line we ensure that we use only entries in proper format: string number number
    echo $output
}

# 0 is label, 1 is label_count
label_params=( $(get_interval_label_and_count) )

mv $latest ${WORK_DIR}/${HOST}/$(date +%F_%T)_${label_params[0]}/
ls -dt ${WORK_DIR}/${HOST}/*_${label_params[0]} | tail -n +${label_params[1]} | xargs rm -rf
