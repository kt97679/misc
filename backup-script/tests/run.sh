#!/bin/bash

set -uo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BACKUP_SCRIPT=${BACKUP_SCRIPT:-${PROJECT_DIR}/backup.sh}
REAL_DATE=$(command -v date)
REAL_STAT=$(command -v stat)
TEST_NOW=1782993600 # 2026-07-02T12:00:00Z
PASS=0
FAIL=0
SKIP=0
SANDBOX=

fail() {
    printf '    %s\n' "$*" >&2
    return 1
}

assert_eq() {
    [[ $1 == "$2" ]] || fail "expected [$2], got [$1]"
}

assert_contains() {
    [[ $1 == *"$2"* ]] || fail "expected output to contain: $2"
}

assert_not_contains() {
    [[ $1 != *"$2"* ]] || fail "expected output not to contain: $2"
}

assert_exists() {
    [[ -e $1 ]] || fail "expected to exist: $1"
}

assert_not_exists() {
    [[ ! -e $1 ]] || fail "expected not to exist: $1"
}

assert_mode() {
    local mode

    mode=$(stat -c %a -- "$1") || return
    assert_eq "$mode" "$2"
}

assert_file_contains() {
    grep -Fq -- "$2" "$1" ||
        fail "expected $1 to contain: $2; actual: $(<"$1")"
}

assert_file_not_contains() {
    ! grep -Fq -- "$2" "$1" ||
        fail "expected $1 not to contain: $2; actual: $(<"$1")"
}

setup() {
    unset TEST_FINDMNT_FAIL TEST_FINDMNT_FAIL_ON_CALL TEST_MOUNT_TARGET TEST_MOUNT_SOURCE TEST_RSYNC_DELETE_PATH
    unset TEST_MOUNT_FSTYPE TEST_MOUNT_FSTYPE_CHANGE_ON_CALL TEST_MOUNT_FSTYPE_CHANGED TEST_BTRFS_FAIL_ON
    unset TEST_ZFS_FAIL_ON TEST_BTRFS_NOOP_ON WORK_DIR
    SANDBOX=$(mktemp -d /tmp/backup-script-test.XXXXXX)
    export TEST_STATE=${SANDBOX}/state
    export TEST_BIN=${SANDBOX}/bin
    export BACKUP_ROOT=${SANDBOX}/backup-store
    export LOG_DIR=${SANDBOX}/log
    export LOCK_DIR=${SANDBOX}/lock
    export EXPECTED_MOUNT_POINT=$BACKUP_ROOT
    export EXPECTED_MOUNT_SOURCE=/dev/test-backup
    export TEST_HOSTNAME=local-test
    export TEST_NOW REAL_DATE REAL_STAT
    export TZ=UTC
    mkdir -p -- "$TEST_STATE" "$TEST_BIN" "$BACKUP_ROOT/$TEST_HOSTNAME" "$LOG_DIR" "$LOCK_DIR"
    printf '0|\n' >"$TEST_STATE/rsync.plan"
    printf '2000000 5000\n' >"$TEST_STATE/df.plan"
    # The host being backed up: a plain ext4 root unless a test says otherwise.
    export MOUNTINFO=$TEST_STATE/mountinfo
    printf '1 0 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n' >"$MOUNTINFO"
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=2'
    unset SUDO_USER

    cat >"$TEST_BIN/hostname" <<'EOF'
#!/bin/bash
printf '%s\n' "$TEST_HOSTNAME"
EOF

    cat >"$TEST_BIN/date" <<'EOF'
#!/bin/bash
case "$*" in
    '+%s'|'-u +%s') printf '%s\n' "$TEST_NOW" ;;
    '+%F_%T'|'-u +%F_%T') "$REAL_DATE" -u -d "@$TEST_NOW" +%F_%T ;;
    '-u +%FT%TZ') "$REAL_DATE" -u -d "@$TEST_NOW" +%FT%TZ ;;
    *) exec "$REAL_DATE" "$@" ;;
esac
EOF

cat >"$TEST_BIN/findmnt" <<'EOF'
#!/bin/bash
count_file=$TEST_STATE/findmnt.count
count=0
[[ -f $count_file ]] && read -r count <"$count_file"
((++count))
printf '%s\n' "$count" >"$count_file"
[[ ${TEST_FINDMNT_FAIL:-0} == 0 ]] || exit 1
[[ ${TEST_FINDMNT_FAIL_ON_CALL:-0} != "$count" ]] || exit 1
while (($#)); do
    [[ $1 == -o ]] && { field=$2; shift 2; continue; }
    shift
done
fstype=${TEST_MOUNT_FSTYPE:-ext4}
if [[ ${TEST_MOUNT_FSTYPE_CHANGE_ON_CALL:-} ]] && ((count >= TEST_MOUNT_FSTYPE_CHANGE_ON_CALL)); then
    fstype=$TEST_MOUNT_FSTYPE_CHANGED
fi
case $field in
    TARGET) printf '%s\n' "${TEST_MOUNT_TARGET:-$BACKUP_ROOT}" ;;
    SOURCE) printf '%s\n' "${TEST_MOUNT_SOURCE:-/dev/test-backup}" ;;
    FSTYPE) printf '%s\n' "$fstype" ;;
    FSTYPE,TARGET) printf '%s %s\n' "$fstype" "${TEST_MOUNT_TARGET:-$BACKUP_ROOT}" ;;
    *) exit 2 ;;
esac
EOF

    cat >"$TEST_BIN/df" <<'EOF'
#!/bin/bash
count_file=$TEST_STATE/df.count
count=0
[[ -f $count_file ]] && read -r count <"$count_file"
((++count))
printf '%s\n' "$count" >"$count_file"
line=$(sed -n "${count}p" "$TEST_STATE/df.plan")
[[ $line ]] || line=$(tail -n 1 "$TEST_STATE/df.plan")
printf 'Avail IAvail\n%s\n' "${line:-2000000 5000}"
EOF

    cat >"$TEST_BIN/rsync" <<'EOF'
#!/bin/bash
count_file=$TEST_STATE/rsync.count
count=0
[[ -f $count_file ]] && read -r count <"$count_file"
((++count))
printf '%s\n' "$count" >"$count_file"
printf 'rsync\n' >>"$TEST_STATE/events"
printf '%q ' "$@" >>"$TEST_STATE/rsync.calls"
printf '\n' >>"$TEST_STATE/rsync.calls"

destination=${!#}
mkdir -p -- "$destination"
touch -- "${destination}/partial-${count}"

if [[ ${TEST_RSYNC_DELETE_PATH:-} ]]; then
    for arg; do
        [[ $arg == --delete-delay ]] && rm -f -- "$destination/$TEST_RSYNC_DELETE_PATH"
    done
fi

line=$(sed -n "${count}p" "$TEST_STATE/rsync.plan")
[[ $line ]] || line=$(tail -n 1 "$TEST_STATE/rsync.plan")
rc=${line%%|*}
message=${line#*|}
[[ $message == "$line" ]] && message=
[[ $message ]] && printf '%s\n' "$message" >&2
((rc == 0)) || exit "$rc"
touch -- "${destination}/success-${count}"
EOF

    chmod +x -- "$TEST_BIN"/*
    export PATH=${TEST_BIN}:/usr/bin:/bin
}

teardown() {
    [[ -z ${SANDBOX:-} ]] || rm -rf -- "$SANDBOX"
    SANDBOX=
}

write_config() {
    local host=$1
    shift
    mkdir -p -- "$BACKUP_ROOT/$host"
    printf '%s\n' "$@" >"$BACKUP_ROOT/$host/.config"
}

snapshot() {
    local host=$1 name=$2 timestamp=$3
    mkdir -p -- "$BACKUP_ROOT/$host/$name"
    : >"$BACKUP_ROOT/$host/$name/.complete"
    touch -d "@$timestamp" -- "$BACKUP_ROOT/$host/$name"
}

run_backup() {
    local host=${1:-$TEST_HOSTNAME}

    if ((UID == 0)); then
        RUN_OUTPUT=$(bash "$BACKUP_SCRIPT" "$host" 2>&1)
    else
        RUN_OUTPUT=$(unshare -Ur -- bash "$BACKUP_SCRIPT" "$host" 2>&1)
    fi
    RUN_STATUS=$?
}

# Turns the test's backup drive into a btrfs one. Subvolumes are emulated as
# directories holding a .test-subvolume file: the stat fake reports inode 256
# for those, which is how the script recognizes a subvolume, and the btrfs fake
# creates, snapshots and deletes them.
use_btrfs() {
    export TEST_MOUNT_FSTYPE=btrfs
    printf '20000000 0\n' >"$TEST_STATE/df.plan" # ~19 GiB free; btrfs reports no inodes

    cat >"$TEST_BIN/btrfs" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_STATE/btrfs.calls"
printf 'btrfs %s %s\n' "$1" "$2" >>"$TEST_STATE/events"
if [[ ${TEST_BTRFS_FAIL_ON:-} == "$1 $2" ]]; then
    echo "ERROR: simulated failure: $*" >&2
    exit 1
fi
[[ ${TEST_BTRFS_NOOP_ON:-} == "$1 $2" ]] && exit 0
case "$1 $2" in
    'subvolume create')
        mkdir -- "$3" && : >"$3/.test-subvolume" ;;
    'subvolume snapshot')
        [[ $3 == -r && -e $4/.test-subvolume && ! -e $5 ]] || exit 1
        cp -a -- "$4" "$5" ;;
    'subvolume delete')
        [[ -e $3/.test-subvolume ]] || { echo "ERROR: Not a Btrfs subvolume: $3" >&2; exit 1; }
        rm -rf -- "$3" ;;
    'subvolume sync' | 'filesystem sync') ;;
    *) exit 2 ;;
esac
EOF

    cat >"$TEST_BIN/stat" <<'EOF'
#!/bin/bash
if [[ $1 == -f && $2 == -c && $3 == %T ]]; then printf 'btrfs\n'; exit 0; fi
if [[ $1 == -c && $2 == %i && $3 == -- && -e $4/.test-subvolume ]]; then printf '256\n'; exit 0; fi
exec "$REAL_STAT" "$@"
EOF

    chmod +x -- "$TEST_BIN/btrfs" "$TEST_BIN/stat"
}

subvolume_snapshot() {
    local host=$1 name=$2 timestamp=$3
    snapshot "$host" "$name" "$timestamp"
    : >"$BACKUP_ROOT/$host/$name/.test-subvolume"
    touch -d "@$timestamp" -- "$BACKUP_ROOT/$host/$name"
}

# The order in which rsync, btrfs and zfs were called, e.g.
# "zfs-snapshot rsync subvolume-snapshot".
events() {
    [[ -f $TEST_STATE/events ]] || return 0
    awk '{
        if ($1 == "rsync") print "rsync"
        else if ($1 == "zfs") print "zfs-" $2
        else print $2 "-" $3
    }' "$TEST_STATE/events" | paste -sd ' '
}

# Puts the backed-up host's /home and /etc on ZFS, laid out like an Ubuntu install:
# the root dataset holds /home and /etc, and the user's home is its own dataset.
# The pool names are made up, so even a real zfs binary could never act on them.
# The zfs fake records calls; `zfs list` prints lines of zfs.snapshots that belong
# to the dataset asked for.
use_zfs_source() {
    cat >"$MOUNTINFO" <<'EOF'
22 1 0:21 / / rw,relatime shared:1 - zfs testpool/ROOT/system rw,xattr,posixacl
23 22 0:22 / /boot rw,relatime shared:2 - zfs bootpool/BOOT/system rw,xattr,posixacl
24 22 0:23 / /proc rw,nosuid,nodev,noexec,relatime shared:3 - proc proc rw
40 22 0:38 / /home/user rw,relatime shared:20 - zfs testpool/USERDATA/user rw,xattr,posixacl
41 22 0:39 / /var rw,relatime shared:21 - zfs testpool/var rw,xattr,posixacl
45 40 0:45 / /home/user/.zfs/snapshot/autosnap_2026-07-02_11:00:00_hourly ro,relatime shared:25 - zfs testpool/USERDATA/user@autosnap_2026-07-02_11:00:00_hourly ro
EOF

    cat >"$TEST_BIN/zfs" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_STATE/zfs.calls"
printf 'zfs %s\n' "$1" >>"$TEST_STATE/events"
if [[ ${TEST_ZFS_FAIL_ON:-} == "$1" ]]; then
    echo "cannot $1: simulated failure" >&2
    exit 1
fi
case $1 in
    snapshot | destroy) ;;
    list)
        [[ ! -f $TEST_STATE/zfs.snapshots ]] ||
            awk -v prefix="${!#}@" 'index($0, prefix) == 1' "$TEST_STATE/zfs.snapshots"
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x -- "$TEST_BIN/zfs"
}

pending_deletions() {
    find "$BACKUP_ROOT/$TEST_HOSTNAME" -maxdepth 1 -name '.deleting-*' | wc -l
}

test_sudo_reexec_preserves_host() {
    ((UID != 0)) || return 77
    cat >"$TEST_BIN/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_STATE/sudo.args"
exit 73
EOF
    chmod +x "$TEST_BIN/sudo"

    RUN_OUTPUT=$(bash "$BACKUP_SCRIPT" explicit-host 2>&1)
    RUN_STATUS=$?
    assert_eq "$RUN_STATUS" 73 || return
    assert_file_contains "$TEST_STATE/sudo.args" '--preserve-env=BACKUP_ROOT,EXPECTED_MOUNT_POINT,EXPECTED_MOUNT_SOURCE' || return
    assert_file_contains "$TEST_STATE/sudo.args" 'explicit-host' || return
}

test_rejects_wrong_mount() {
    export TEST_MOUNT_TARGET=/
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" "BACKUP_ROOT is on mount /, expected $BACKUP_ROOT" || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_rejects_wrong_mount_source() {
    export TEST_MOUNT_SOURCE=/dev/wrong-disk
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'BACKUP_ROOT source is /dev/wrong-disk, expected /dev/test-backup' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_rejects_untrusted_config() {
    chmod 0666 "$BACKUP_ROOT/$TEST_HOSTNAME/.config"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'config must be root-owned and not group/world writable' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_rejects_untrusted_host_directory() {
    chmod 0777 "$BACKUP_ROOT/$TEST_HOSTNAME"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'host directory must be root-owned and not group/world writable' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_rejects_invalid_host() {
    run_backup '../escape'
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'invalid host name' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_rejects_missing_host_directory() {
    run_backup missing-host
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" "host directory is missing or unsafe: $BACKUP_ROOT/missing-host" || return
}

test_lock_contention_stops_before_rsync() {
    cat >"$TEST_BIN/flock" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_BIN/flock"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'another backup for local-test is in progress' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_local_success_uses_link_dest_and_rotates() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/success-1" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/.complete" || return
    assert_mode "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" 755 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" || return
    assert_file_contains "$TEST_STATE/rsync.calls" "--link-dest=$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly" || return
    assert_file_contains "$TEST_STATE/rsync.calls" '/home /etc' || return
    assert_file_contains "$TEST_STATE/rsync.calls" '-aHv' || return
    assert_file_not_contains "$TEST_STATE/rsync.calls" '-A' || return
    assert_file_not_contains "$TEST_STATE/rsync.calls" '-X' || return
    assert_file_contains "$TEST_STATE/rsync.calls" '--numeric-ids' || return
    assert_file_contains "$TEST_STATE/rsync.calls" '--delete-delay' || return
    assert_file_contains "$TEST_STATE/rsync.calls" '--partial-dir=.rsync-partial' || return
}

test_log_is_rotated_and_run_is_timed() {
    local log=$LOG_DIR/backup.sh.$TEST_HOSTNAME.log

    printf 'previous current log\n' >"$log"
    printf 'obsolete old log\n' >"$log.old"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$log.old" 'previous current log' || return
    assert_file_not_contains "$log.old" 'obsolete old log' || return
    assert_file_not_contains "$log" 'previous current log' || return
    assert_file_contains "$log" 'Backup started: 2026-07-02T12:00:00Z' || return
    assert_file_contains "$log" 'Backup finished: 2026-07-02T12:00:00Z (status=0)' || return
    assert_file_contains "$log" 'Total run time: 0 seconds' || return
}

test_runtime_directory_modes_are_normalized() {
    chmod 0700 "$LOG_DIR"
    chmod 0755 "$LOCK_DIR"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_mode "$LOG_DIR" 755 || return
    assert_mode "$LOCK_DIR" 700 || return
}

test_failure_log_records_status_and_runtime() {
    local log=$LOG_DIR/backup.sh.$TEST_HOSTNAME.log

    printf '23|connection reset by peer\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 23 || return
    assert_file_contains "$log" 'Backup finished: 2026-07-02T12:00:00Z (status=23)' || return
    assert_file_contains "$log" 'Total run time: 0 seconds' || return
}

test_remote_backup_builds_ssh_sources() {
    write_config remote-host 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=2'
    export SUDO_USER=alice
    run_backup remote-host
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/rsync.calls" 'BatchMode=yes' || return
    assert_file_contains "$TEST_STATE/rsync.calls" 'ConnectTimeout=30' || return
    assert_file_contains "$TEST_STATE/rsync.calls" 'alice@remote-host:/home' || return
    assert_file_contains "$TEST_STATE/rsync.calls" 'alice@remote-host:/etc' || return
}

test_remote_backup_requires_sudo_user() {
    write_config remote-host 'RETENTION=("hourly 3600 168")'
    run_backup remote-host
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'SUDO_USER is required for remote backup of remote-host' || return
}

test_non_space_rsync_failure_keeps_latest() {
    printf '23|connection reset by peer\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 23 || return
    assert_contains "$RUN_OUTPUT" 'destination does not look space-constrained' || return
    assert_contains "$RUN_OUTPUT" 'Keeping staging directory as incomplete' || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/partial-1" || return
}

test_backup_device_io_error_keeps_latest() {
    printf '11|Input/output error\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 11 || return
    assert_contains "$RUN_OUTPUT" 'destination does not look space-constrained' || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/partial-1" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
}

test_vanished_source_files_complete_snapshot() {
    printf '24|file has vanished: /home/changing-file\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_contains "$RUN_OUTPUT" 'accepting snapshot after source files vanished' || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/partial-1" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" || return
}

test_enospc_failure_cleans_oldest_and_retries() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_07:00:00_hourly 1782975600
    snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    printf '28|No space left on device\n0|\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_07:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/success-2" || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 2 || return
    assert_contains "$RUN_OUTPUT" 'rsync failed due to likely destination space/inode exhaustion' || return
}

test_low_space_after_success_cleans_and_retries() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_07:00:00_hourly 1782975600
    snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    printf '1000000 5000\n2000000 5000\n' >"$TEST_STATE/df.plan"
    printf '0|\n0|\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_07:00:00_hourly" || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 2 || return
    assert_contains "$RUN_OUTPUT" 'Destination is below free-space reserve after rsync' || return
}

test_cleanup_refuses_to_cross_minimum() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    printf '1000000 5000\n' >"$TEST_STATE/df.plan"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'no label has a backup to delete without going below MIN_PER_LABEL_WHEN_FULL=2' || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/partial-1" || return
}

test_retention_prunes_oldest_snapshots() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    snapshot "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_09:00:00_hourly" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_11:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
    assert_eq "$(find "$BACKUP_ROOT/$TEST_HOSTNAME" -maxdepth 1 -type d -name '*_hourly' | wc -l)" 2 || return
}

test_recycles_due_snapshot_as_staging() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    : >"$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_09:00:00_hourly/removed-from-host"
    export TEST_RSYNC_DELETE_PATH=removed-from-host
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_09:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/removed-from-host" || return
    assert_file_contains "$TEST_STATE/rsync.calls" "--link-dest=$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly" || return
    assert_contains "$RUN_OUTPUT" 'Recycling due snapshot as staging' || return
}

test_recycled_snapshot_failure_remains_incomplete() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    printf '23|connection reset by peer\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 23 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_09:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/partial-1" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/.complete" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
    assert_file_contains "$TEST_STATE/rsync.calls" "--link-dest=$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly" || return
}

test_recycled_vanished_source_files_complete_without_stale_files() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    : >"$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_09:00:00_hourly/removed-from-host"
    export TEST_RSYNC_DELETE_PATH=removed-from-host
    printf '24|file has vanished: /home/changing-file\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/.complete" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/removed-from-host" || return
    assert_contains "$RUN_OUTPUT" 'accepting snapshot after source files vanished' || return
}

test_existing_staging_preserves_resume_and_deletes_due_snapshot() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    mkdir -p -- "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete"
    : >"$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/resume"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_09:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/resume" || return
    assert_contains "$RUN_OUTPUT" 'preserving incomplete staging directory' || return
}

test_existing_staging_marker_is_removed_before_failed_resume() {
    mkdir -p -- "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete"
    : >"$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/.complete"
    printf '23|connection reset by peer\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 23 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/.complete" || return
}

test_resumed_staging_removes_files_deleted_from_host() {
    mkdir -p -- "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete"
    : >"$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/removed-from-host"
    export TEST_RSYNC_DELETE_PATH=removed-from-host
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/removed-from-host" || return
}

test_retention_prunes_expired_snapshots_for_all_labels() {
    write_config "$TEST_HOSTNAME" \
        'RETENTION=("hourly 3600 168" "daily 86400 180" "weekly 604800 104" "monthly 2419200 52")' \
        'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-06-25_11:00:00_hourly 1782385200
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_monthly" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-06-25_11:00:00_hourly" || return
}

test_selects_first_due_retention_interval() {
    write_config "$TEST_HOSTNAME" \
        'RETENTION=("hourly 3600 168" "daily 86400 180" "weekly 604800 104" "monthly 2419200 52")'
    snapshot "$TEST_HOSTNAME" 2026-07-01_12:00:00_monthly 1782907200
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_weekly" || return
}

test_invalid_config_fails_without_rotation() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("invalid")'
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'invalid retention entry' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" || return
}

test_df_failure_aborts_without_cleanup() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_07:00:00_hourly 1782975600
    snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    cat >"$TEST_BIN/df" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_BIN/df"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" "failed to read free space for $BACKUP_ROOT" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_07:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_08:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_09:00:00_hourly" || return
}

test_malformed_df_output_aborts_without_cleanup() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    cat >"$TEST_BIN/df" <<'EOF'
#!/bin/bash
printf 'Avail IAvail\nnot-a-number 5000\n'
EOF
    chmod +x "$TEST_BIN/df"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" "invalid free-space data for $BACKUP_ROOT" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly" || return
}

test_findmnt_failure_aborts_before_rsync() {
    export TEST_FINDMNT_FAIL=1
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" "cannot determine filesystem mount for $BACKUP_ROOT" || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_unplugged_backup_disk_aborts_without_publishing_snapshot() {
    export TEST_FINDMNT_FAIL_ON_CALL=7
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" "cannot determine filesystem mount for $BACKUP_ROOT" || return
    assert_exists "$TEST_STATE/rsync.count" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/partial-1" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
}

test_unsafe_staging_stops_before_rsync() {
    ln -s -- / "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'unsafe staging path' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_unsafe_staging_marker_stops_before_rsync() {
    mkdir -p -- "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete"
    ln -s -- / "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/.complete"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'unsafe staging marker' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_incomplete_staging_is_resumed() {
    printf '23|connection reset by peer\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 23 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/partial-1" || return
    assert_mode "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" 755 || return

    chmod 0700 -- "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete"
    printf '0|\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/partial-1" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/success-2" || return
    assert_mode "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" 755 || return
    assert_contains "$RUN_OUTPUT" 'Resuming incomplete staging directory' || return
}

test_pending_deletion_is_finalized_before_rsync() {
    local deleting=$BACKUP_ROOT/$TEST_HOSTNAME/.deleting-2026-07-02_10:00:00_hourly-1234

    mkdir -p -- "$deleting"
    : >"$deleting/.complete"
    : >"$deleting/leftover"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$deleting" || return
    assert_contains "$RUN_OUTPUT" "Finalizing interrupted cleanup: $deleting" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/success-1" || return
}

test_markerless_pending_deletion_stops_before_rsync() {
    local deleting=$BACKUP_ROOT/$TEST_HOSTNAME/.deleting-2026-07-02_10:00:00_hourly-1234

    mkdir -p -- "$deleting"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'pending deletion is missing a regular completion marker' || return
    assert_exists "$deleting" || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_invalid_pending_deletion_marker_stops_before_rsync() {
    local deleting=$BACKUP_ROOT/$TEST_HOSTNAME/.deleting-2026-07-02_10:00:00_hourly-1234

    mkdir -p -- "$deleting"
    printf 'snapshot_epoch=not-a-number\n' >"$deleting/.complete"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'pending deletion has an invalid completion marker' || return
    assert_exists "$deleting" || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_unsafe_pending_deletion_stops_before_rsync() {
    ln -s -- / "$BACKUP_ROOT/$TEST_HOSTNAME/.deleting-2026-07-02_10:00:00_hourly-1234"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'unsafe pending deletion path' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_snapshot_collision_does_not_nest_staging() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_12:00:00_hourly "$TEST_NOW"
    : >"$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/original"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'snapshot already exists' || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/original" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/.latest.incomplete" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" || return
}

test_legacy_snapshot_is_marked_and_reused() {
    mkdir -p "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/.complete" || return
    assert_file_contains "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/.complete" 'snapshot_epoch=' || return
    assert_file_contains "$TEST_STATE/rsync.calls" "--link-dest=$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly" || return
}

test_previous_snapshot_uses_name_not_mtime() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782992000
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782970000
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/rsync.calls" "--link-dest=$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly" || return
}

test_unmarked_snapshot_is_ignored_when_legacy_trust_disabled() {
    write_config "$TEST_HOSTNAME" \
        'RETENTION=("hourly 3600 168")' \
        'MIN_PER_LABEL_WHEN_FULL=2' \
        'ADOPT_UNMARKED_BACKUPS=0'
    mkdir -p "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    if grep -Fq -- '--link-dest=' "$TEST_STATE/rsync.calls"; then
        fail 'unmarked snapshot was used as link-dest' || return
    fi
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/.complete" || return
}

test_invalid_snapshot_marker_is_ignored() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    printf 'snapshot_epoch=not-a-number\n' >"$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/.complete"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    if grep -Fq -- '--link-dest=' "$TEST_STATE/rsync.calls"; then
        fail 'snapshot with an invalid completion marker was used as link-dest' || return
    fi
}

test_symlinked_snapshot_marker_is_ignored() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    rm -- "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/.complete"
    ln -s -- / "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/.complete"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    if grep -Fq -- '--link-dest=' "$TEST_STATE/rsync.calls"; then
        fail 'snapshot with a symlinked completion marker was used as link-dest' || return
    fi
}

test_exact_retention_boundary_selects_next_interval() {
    write_config "$TEST_HOSTNAME" \
        'RETENTION=("hourly 3600 168" "daily 86400 180" "weekly 604800 104")'
    snapshot "$TEST_HOSTNAME" 2026-07-02_11:00:00_weekly 1782990000
    snapshot "$TEST_HOSTNAME" 2026-07-01_12:00:00_daily 1782907200
    snapshot "$TEST_HOSTNAME" 2026-07-02_11:30:00_hourly 1782991800
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_daily" || return
}

test_emergency_cleanup_prefers_shortest_interval() {
    write_config "$TEST_HOSTNAME" \
        'RETENTION=("hourly 3600 10" "daily 86400 10")' \
        'MIN_PER_LABEL_WHEN_FULL=2'
    snapshot "$TEST_HOSTNAME" 2026-07-02_07:00:00_hourly 1782975600
    snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot "$TEST_HOSTNAME" 2026-06-29_12:00:00_daily 1782734400
    snapshot "$TEST_HOSTNAME" 2026-06-30_12:00:00_daily 1782820800
    snapshot "$TEST_HOSTNAME" 2026-07-01_12:00:00_daily 1782907200
    printf '1000000 5000\n2000000 5000\n' >"$TEST_STATE/df.plan"
    printf '0|\n0|\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_07:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-06-29_12:00:00_daily" || return
}

# --- filesystem detection ---------------------------------------------------

test_unsupported_filesystem_is_rejected() {
    export TEST_MOUNT_FSTYPE=vfat
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'unsupported filesystem on backup drive: vfat' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.staging" || return
}

test_xfs_uses_hardlink_mode() {
    export TEST_MOUNT_FSTYPE=xfs
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_contains "$RUN_OUTPUT" 'Backup mode: hardlink (xfs)' || return
    assert_file_contains "$TEST_STATE/rsync.calls" "--link-dest=$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly" || return
}

test_hardlink_mode_never_calls_btrfs() {
    use_btrfs
    export TEST_MOUNT_FSTYPE=ext4
    printf '2000000 5000\n' >"$TEST_STATE/df.plan"
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 1")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    snapshot "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_contains "$RUN_OUTPUT" 'Recycling due snapshot as staging' || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_11:00:00_hourly" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
    assert_not_exists "$TEST_STATE/btrfs.calls" || return
}

test_filesystem_change_during_run_aborts_without_publishing() {
    # Call 7 is the first mount check after rsync (see the unplugged-disk test).
    export TEST_MOUNT_FSTYPE_CHANGE_ON_CALL=7 TEST_MOUNT_FSTYPE_CHANGED=btrfs
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" "filesystem of $BACKUP_ROOT changed from ext4 to btrfs" || return
    assert_exists "$TEST_STATE/rsync.count" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete/partial-1" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
}

# --- hardlink mode gaps and excludes ----------------------------------------

test_rsync_never_copies_acls_or_xattrs() {
    local arg

    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    # Catches -A/-X inside combined short options (like -aHvA) and the long forms.
    for arg in $(<"$TEST_STATE/rsync.calls"); do
        case $arg in
            --acls | --xattrs | -[AX]* | -[!-]*[AX]*) fail "rsync was asked to copy ACLs or xattrs: $arg" || return ;;
        esac
    done
}

test_rsync_compares_timestamps_to_the_nanosecond() {
    # Without this, a file rewritten at the same size within the same second as
    # the previous copy is skipped and the backup keeps the old version.
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/rsync.calls" '--modify-window=-1' || return
}

test_low_inodes_after_success_cleans_and_retries() {
    snapshot "$TEST_HOSTNAME" 2026-07-02_07:00:00_hourly 1782975600
    snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    printf '2000000 500\n2000000 5000\n' >"$TEST_STATE/df.plan"
    printf '0|\n0|\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_07:00:00_hourly" || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 2 || return
    assert_contains "$RUN_OUTPUT" 'Destination is below free-space reserve after rsync' || return
}

test_excludes_are_passed_to_rsync() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=2' \
        "EXCLUDES=(.cache/ 'Trash/')"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/rsync.calls" '--exclude=.cache/' || return
    assert_file_contains "$TEST_STATE/rsync.calls" '--exclude=Trash/' || return
    assert_file_contains "$TEST_STATE/rsync.calls" '--delete-excluded' || return
}

test_no_excludes_by_default() {
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_not_contains "$TEST_STATE/rsync.calls" '--exclude' || return
    assert_file_not_contains "$TEST_STATE/rsync.calls" '--delete-excluded' || return
}

test_empty_exclude_pattern_is_rejected() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' "EXCLUDES=('')"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'empty pattern in EXCLUDES' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

# --- btrfs mode -------------------------------------------------------------

test_btrfs_snapshots_persistent_staging_subvolume() {
    local host_dir=$BACKUP_ROOT/$TEST_HOSTNAME

    use_btrfs
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_contains "$RUN_OUTPUT" 'Backup mode: btrfs (btrfs)' || return
    assert_file_contains "$TEST_STATE/btrfs.calls" "subvolume create $host_dir/.staging" || return
    assert_file_contains "$TEST_STATE/btrfs.calls" \
        "subvolume snapshot -r $host_dir/.staging $host_dir/2026-07-02_12:00:00_hourly" || return
    assert_exists "$host_dir/2026-07-02_12:00:00_hourly/success-1" || return
    assert_file_contains "$host_dir/2026-07-02_12:00:00_hourly/.complete" "snapshot_epoch=$TEST_NOW" || return
    assert_mode "$host_dir/2026-07-02_12:00:00_hourly" 755 || return
    assert_exists "$host_dir/.staging/.test-subvolume" || return
    assert_not_exists "$host_dir/.staging/.complete" || return
    assert_not_exists "$host_dir/.latest.incomplete" || return
    assert_file_contains "$TEST_STATE/rsync.calls" "$host_dir/.staging/" || return
    assert_file_not_contains "$TEST_STATE/rsync.calls" '--link-dest' || return
}

test_btrfs_next_run_reuses_staging() {
    use_btrfs
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    local -x TEST_NOW=$((TEST_NOW + 3600))
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_eq "$(grep -c 'subvolume create' "$TEST_STATE/btrfs.calls")" 1 || return
    # The staging copy carries over, so the second snapshot holds both rsync results.
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_13:00:00_hourly/success-1" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_13:00:00_hourly/success-2" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
}

test_btrfs_retention_deletes_subvolumes_without_waiting() {
    local host_dir=$BACKUP_ROOT/$TEST_HOSTNAME

    use_btrfs
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$host_dir/2026-07-02_09:00:00_hourly" || return
    assert_not_exists "$host_dir/2026-07-02_10:00:00_hourly" || return
    assert_exists "$host_dir/2026-07-02_11:00:00_hourly" || return
    assert_exists "$host_dir/2026-07-02_12:00:00_hourly" || return
    assert_file_contains "$TEST_STATE/btrfs.calls" "subvolume delete $host_dir/2026-07-02_09:00:00_hourly" || return
    assert_file_contains "$TEST_STATE/btrfs.calls" "subvolume delete $host_dir/2026-07-02_10:00:00_hourly" || return
    assert_not_contains "$RUN_OUTPUT" 'Recycling' || return
    assert_file_not_contains "$TEST_STATE/btrfs.calls" 'sync' || return
    assert_eq "$(pending_deletions)" 0 || return
}

test_btrfs_low_space_cleanup_waits_for_reclaim() {
    use_btrfs
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_07:00:00_hourly 1782975600
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    printf '1000000 0\n20000000 0\n' >"$TEST_STATE/df.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_07:00:00_hourly" || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 2 || return
    assert_contains "$RUN_OUTPUT" 'Destination is below free-space reserve after rsync' || return
    assert_eq "$(events)" \
        'subvolume-create rsync subvolume-delete subvolume-sync filesystem-sync rsync subvolume-snapshot' || return
}

test_btrfs_enospc_cleans_waits_and_retries() {
    use_btrfs
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_07:00:00_hourly 1782975600
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    printf '28|No space left on device\n0|\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_07:00:00_hourly" || return
    assert_contains "$RUN_OUTPUT" 'rsync failed due to likely destination space/inode exhaustion' || return
    assert_eq "$(events)" \
        'subvolume-create rsync subvolume-delete subvolume-sync filesystem-sync rsync subvolume-snapshot' || return
}

test_btrfs_ignores_missing_inode_count() {
    use_btrfs # df reports 0 free inodes, as btrfs does
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_contains "$RUN_OUTPUT" 'below free-space reserve' || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
}

test_btrfs_default_reserve_is_10_gib() {
    use_btrfs
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    printf '5000000 5000\n' >"$TEST_STATE/df.plan" # ~4.8 GiB: enough on ext4, not on btrfs
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'Destination is below free-space reserve after rsync' || return
    assert_contains "$RUN_OUTPUT" 'no label has a backup to delete without going below MIN_PER_LABEL_WHEN_FULL=2' || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
}

test_btrfs_reserve_can_be_overridden() {
    use_btrfs
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=2' 'FREE_SPACE_RESERVE=1000K'
    printf '2000000 0\n' >"$TEST_STATE/df.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_contains "$RUN_OUTPUT" 'below free-space reserve' || return
}

test_btrfs_plain_directory_snapshot_is_removed_without_btrfs() {
    local host_dir=$BACKUP_ROOT/$TEST_HOSTNAME

    use_btrfs
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800 # copied over from an ext4 drive
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$host_dir/2026-07-02_09:00:00_hourly" || return
    assert_not_exists "$host_dir/2026-07-02_10:00:00_hourly" || return
    assert_exists "$host_dir/2026-07-02_11:00:00_hourly" || return
    assert_file_not_contains "$TEST_STATE/btrfs.calls" '2026-07-02_09:00:00_hourly' || return
    assert_file_contains "$TEST_STATE/btrfs.calls" "subvolume delete $host_dir/2026-07-02_10:00:00_hourly" || return
    assert_eq "$(pending_deletions)" 0 || return
}

test_btrfs_legacy_plain_directory_is_marked() {
    use_btrfs
    mkdir -p "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/.complete" 'snapshot_epoch=' || return
    assert_file_not_contains "$TEST_STATE/rsync.calls" '--link-dest' || return
}

test_btrfs_markerless_subvolume_is_left_alone() {
    local dir=$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_09:00:00_hourly

    use_btrfs
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 1")' 'MIN_PER_LABEL_WHEN_FULL=1'
    mkdir -p -- "$dir"
    : >"$dir/.test-subvolume"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_contains "$RUN_OUTPUT" 'ignoring btrfs snapshot without a completion marker' || return
    assert_exists "$dir" || return
    assert_not_exists "$dir/.complete" || return
    assert_file_not_contains "$TEST_STATE/btrfs.calls" '2026-07-02_09:00:00_hourly' || return
}

test_btrfs_staging_must_be_a_subvolume() {
    use_btrfs
    mkdir -p -- "$BACKUP_ROOT/$TEST_HOSTNAME/.staging"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'staging path is not a btrfs subvolume' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_btrfs_rsync_failure_keeps_staging_without_snapshot() {
    use_btrfs
    printf '23|connection reset by peer\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 23 || return
    assert_contains "$RUN_OUTPUT" 'Keeping staging subvolume as it is' || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.staging/partial-1" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
    assert_file_not_contains "$TEST_STATE/btrfs.calls" 'subvolume snapshot' || return
}

test_btrfs_failed_snapshot_is_retried_cleanly() {
    use_btrfs
    export TEST_BTRFS_FAIL_ON='subvolume snapshot'
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return

    unset TEST_BTRFS_FAIL_ON
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/success-2" || return
    assert_file_contains "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/.complete" "snapshot_epoch=$TEST_NOW" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.staging/.complete" || return
}

test_btrfs_snapshot_collision_stops_before_staging() {
    use_btrfs
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_12:00:00_hourly "$TEST_NOW"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'snapshot already exists' || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.staging" || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    assert_not_exists "$TEST_STATE/btrfs.calls" || return
}

# --- ZFS source -------------------------------------------------------------

test_zfs_source_copies_each_dataset_from_one_snapshot() {
    local snap=backup-script-$TEST_NOW staging=$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete

    use_zfs_source
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/zfs.calls" \
        "snapshot testpool/ROOT/system@$snap testpool/USERDATA/user@$snap" || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 3 || return
    assert_file_contains "$TEST_STATE/rsync.calls" "/.zfs/snapshot/$snap/etc/ $staging/etc/" || return
    assert_eq "$(grep -c -- '--modify-window=-1' "$TEST_STATE/rsync.calls")" 3 || return
    assert_file_contains "$TEST_STATE/rsync.calls" \
        "--filter=H\\ /user/ --filter=P\\ /user/ /.zfs/snapshot/$snap/home/ $staging/home/" || return
    assert_file_contains "$TEST_STATE/rsync.calls" "/home/user/.zfs/snapshot/$snap/ $staging/home/user/" || return
    assert_file_not_contains "$TEST_STATE/rsync.calls" 'autosnap' || return
    assert_eq "$(events)" 'zfs-list zfs-list zfs-snapshot rsync rsync rsync zfs-destroy zfs-destroy' || return
    assert_file_contains "$TEST_STATE/zfs.calls" "destroy testpool/ROOT/system@$snap" || return
    assert_file_contains "$TEST_STATE/zfs.calls" "destroy testpool/USERDATA/user@$snap" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/home/user/success-3" || return
}

test_zfs_source_snapshot_is_destroyed_when_rsync_fails() {
    use_zfs_source
    printf '23|connection reset by peer\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 23 || return
    assert_contains "$RUN_OUTPUT" 'Keeping staging directory as incomplete' || return
    assert_eq "$(events)" 'zfs-list zfs-list zfs-snapshot rsync zfs-destroy zfs-destroy' || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly" || return
}

test_zfs_source_failed_snapshot_stops_before_rsync() {
    use_zfs_source
    export TEST_ZFS_FAIL_ON=snapshot
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    assert_file_not_contains "$TEST_STATE/zfs.calls" 'destroy' || return
}

test_zfs_source_stale_snapshots_are_destroyed_first() {
    use_zfs_source
    printf '%s\n' \
        testpool/ROOT/system@autosnap_2026-07-02_11:00:00_hourly \
        testpool/ROOT/system@backup-script-1782990000 \
        testpool/USERDATA/user@backup-script-1782990000 \
        testpool/USERDATA/user@backup-script-manual >"$TEST_STATE/zfs.snapshots"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_contains "$RUN_OUTPUT" \
        'left by an interrupted run: testpool/ROOT/system@backup-script-1782990000' || return
    assert_file_contains "$TEST_STATE/zfs.calls" 'destroy testpool/ROOT/system@backup-script-1782990000' || return
    assert_file_contains "$TEST_STATE/zfs.calls" 'destroy testpool/USERDATA/user@backup-script-1782990000' || return
    assert_file_not_contains "$TEST_STATE/zfs.calls" 'destroy testpool/ROOT/system@autosnap' || return
    assert_file_not_contains "$TEST_STATE/zfs.calls" 'backup-script-manual' || return
    assert_eq "$(events)" \
        'zfs-list zfs-destroy zfs-list zfs-destroy zfs-snapshot rsync rsync rsync zfs-destroy zfs-destroy' || return
}

test_zfs_source_enospc_retry_reuses_snapshot() {
    use_zfs_source
    snapshot "$TEST_HOSTNAME" 2026-07-02_07:00:00_hourly 1782975600
    snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    printf '0|\n28|No space left on device\n0|\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_07:00:00_hourly" || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 5 || return
    assert_eq "$(grep -c '^snapshot ' "$TEST_STATE/zfs.calls")" 1 || return
    assert_eq "$(grep -c '^destroy ' "$TEST_STATE/zfs.calls")" 2 || return
}

test_zfs_source_link_dest_per_tree() {
    local snap=backup-script-$TEST_NOW previous=$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly

    use_zfs_source
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/rsync.calls" "--link-dest=$previous/etc /.zfs/snapshot/$snap/etc/" || return
    assert_file_contains "$TEST_STATE/rsync.calls" "--link-dest=$previous/home /.zfs/snapshot/$snap/home/" || return
    assert_file_contains "$TEST_STATE/rsync.calls" \
        "--link-dest=$previous/home/user /home/user/.zfs/snapshot/$snap/" || return
}

test_zfs_source_with_btrfs_backup_drive() {
    local snap=backup-script-$TEST_NOW host_dir=$BACKUP_ROOT/$TEST_HOSTNAME

    use_btrfs
    use_zfs_source
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/rsync.calls" \
        "/home/user/.zfs/snapshot/$snap/ $host_dir/.staging/home/user/" || return
    assert_exists "$host_dir/2026-07-02_12:00:00_hourly/home/user/success-3" || return
    assert_eq "$(events)" \
        'zfs-list zfs-list zfs-snapshot subvolume-create rsync rsync rsync zfs-destroy zfs-destroy subvolume-snapshot' || return
}

test_zfs_source_excludes_apply_to_every_tree() {
    use_zfs_source
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=2' 'EXCLUDES=(.cache/)'
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_eq "$(grep -c -- '--exclude=.cache/ --delete-excluded' "$TEST_STATE/rsync.calls")" 3 || return
    # The mount-point rules must come first, since rsync uses the first rule that matches.
    assert_file_contains "$TEST_STATE/rsync.calls" '--filter=P\ /user/ --exclude=.cache/' || return
}

test_zfs_source_non_zfs_mount_is_copied_live() {
    local snap=backup-script-$TEST_NOW staging=$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete

    use_zfs_source
    printf '60 40 8:17 / /home/user/data rw,relatime shared:40 - ext4 /dev/sdb1 rw\n' >>"$MOUNTINFO"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 4 || return
    assert_file_contains "$TEST_STATE/rsync.calls" \
        "--filter=H\\ /user/ --filter=P\\ /user/ --filter=H\\ /user/data/ --filter=P\\ /user/data/ /.zfs/snapshot/$snap/home/" || return
    assert_file_contains "$TEST_STATE/rsync.calls" \
        "--filter=H\\ /data/ --filter=P\\ /data/ /home/user/.zfs/snapshot/$snap/ $staging/home/user/" || return
    assert_file_contains "$TEST_STATE/rsync.calls" "/home/user/data/ $staging/home/user/data/" || return
}

test_zfs_source_decodes_escaped_mount_points() {
    local staging=$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete

    use_zfs_source
    printf '61 40 8:18 / /home/user/My\\040Files rw,relatime shared:41 - ext4 /dev/sdc1 rw\n' >>"$MOUNTINFO"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/rsync.calls" "/home/user/My\\ Files/ $staging/home/user/My\\ Files/" || return
}

test_zfs_source_bind_mount_is_copied_live() {
    local staging=$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete

    use_zfs_source
    # A bind mount of a subdirectory of a dataset is not a whole dataset.
    printf '63 40 0:38 /projects /home/user/work rw,relatime shared:43 - zfs testpool/USERDATA/user rw\n' >>"$MOUNTINFO"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/rsync.calls" "/home/user/work/ $staging/home/user/work/" || return
}

test_zfs_source_rejects_wildcards_in_mount_points() {
    use_zfs_source
    printf '62 40 8:19 / /home/user/odd[1] rw,relatime shared:42 - ext4 /dev/sdd1 rw\n' >>"$MOUNTINFO"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'unsupported character in mount point: /home/user/odd[1]' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    assert_not_exists "$TEST_STATE/zfs.calls" || return
}

test_zfs_source_ignored_for_remote_host() {
    use_zfs_source
    write_config remote-host 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=2'
    export SUDO_USER=alice
    run_backup remote-host
    assert_eq "$RUN_STATUS" 0 || return
    assert_file_contains "$TEST_STATE/rsync.calls" 'alice@remote-host:/home alice@remote-host:/etc' || return
    assert_not_exists "$TEST_STATE/zfs.calls" || return
}

test_no_zfs_means_one_live_rsync() {
    use_zfs_source
    printf '1 0 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n' >"$MOUNTINFO"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 1 || return
    assert_file_contains "$TEST_STATE/rsync.calls" '/home /etc' || return
    assert_not_exists "$TEST_STATE/zfs.calls" || return
}

test_zfs_source_requires_zfs_command() {
    [[ -z $(PATH=/usr/bin:/bin command -v zfs) ]] || return 77 # a real zfs is on the test PATH
    use_zfs_source
    rm -f -- "$TEST_BIN/zfs"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'zfs is required to back up from ZFS snapshots' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" || return
}

test_anchored_exclude_pattern_is_rejected() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' 'EXCLUDES=(/home/user/Downloads/)'
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'EXCLUDES patterns must not start with /' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_unreadable_mount_table_stops_before_rsync() {
    export MOUNTINFO=$TEST_STATE/missing-mountinfo
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'cannot read mount table' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

# --- sources that are empty or missing now ------------------------------------
# The fakes never create real snapshot directories, so in these tests every ZFS
# source is missing; whether that is refused depends on the last backup.

# A complete snapshot in which each listed directory holds a file.
snapshot_with_files() {
    local host=$1 name=$2 timestamp=$3 dir
    shift 3
    snapshot "$host" "$name" "$timestamp"
    for dir; do
        mkdir -p -- "$BACKUP_ROOT/$host/$name/$dir"
        : >"$BACKUP_ROOT/$host/$name/$dir/file"
    done
    touch -d "@$timestamp" -- "$BACKUP_ROOT/$host/$name"
}

test_empty_check_refuses_home_missing_from_snapshot() {
    use_zfs_source
    snapshot_with_files "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400 home/user
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" \
        'Error: /home/user has no files now, but the last backup (2026-07-02_10:00:00_hourly) has files there' || return
    assert_contains "$RUN_OUTPUT" "touch $BACKUP_ROOT/$TEST_HOSTNAME/.accept-empty-sources" || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" || return
    assert_eq "$(events)" 'zfs-list zfs-list zfs-snapshot zfs-destroy zfs-destroy' || return
}

test_empty_check_refuses_unmounted_home_dataset() {
    use_zfs_source
    sed -i '/\/home\/user/d' "$MOUNTINFO" # the user's dataset is not mounted, e.g. still locked
    snapshot_with_files "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400 home/user
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'Error: /home/user has no files now' || return
    assert_file_not_contains "$TEST_STATE/zfs.calls" 'testpool/USERDATA/user' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_empty_check_refuses_missing_home_without_zfs() {
    local host_dir=$BACKUP_ROOT/$TEST_HOSTNAME

    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot_with_files "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400 home/backup-test-no-such-user
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'Error: /home/backup-test-no-such-user has no files now' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    # Refused before anything was touched: the snapshot due for recycling is untouched.
    assert_exists "$host_dir/2026-07-02_09:00:00_hourly/.complete" || return
    assert_not_exists "$host_dir/.latest.incomplete" || return
}

test_empty_check_looks_at_the_snapshot_not_live_files() {
    # The live /etc has files, but the snapshot that would be copied doesn't exist
    # here. The check has to look at what rsync will actually read.
    use_zfs_source
    snapshot_with_files "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400 etc
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'Error: /etc has no files now' || return
}

test_empty_check_passes_when_sources_have_files() {
    snapshot_with_files "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400 etc # the real /etc has files
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_contains "$RUN_OUTPUT" 'has no files now' || return
}

test_empty_check_ignores_dirs_empty_in_last_backup() {
    [[ -n $(ls -A /home 2>/dev/null) ]] || return 77 # needs a non-empty /home on the test machine
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    mkdir -p -- "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/home/backup-test-empty-user"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_contains "$RUN_OUTPUT" 'has no files now' || return
}

test_empty_check_leaves_btrfs_staging_untouched() {
    use_btrfs
    use_zfs_source
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    mkdir -p -- "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/home/user"
    : >"$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_10:00:00_hourly/home/user/file"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_not_exists "$TEST_STATE/btrfs.calls" || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_accept_file_allows_one_empty_backup() {
    use_zfs_source
    snapshot_with_files "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400 home/user
    : >"$BACKUP_ROOT/$TEST_HOSTNAME/.accept-empty-sources"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_contains "$RUN_OUTPUT" 'Warning: backing up as empty because' || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 3 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.accept-empty-sources" || return
}

test_accept_file_survives_a_failed_backup() {
    use_zfs_source
    snapshot_with_files "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400 home/user
    : >"$BACKUP_ROOT/$TEST_HOSTNAME/.accept-empty-sources"
    printf '23|connection reset by peer\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 23 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.accept-empty-sources" || return
}

test_symlinked_accept_file_is_ignored() {
    use_zfs_source
    snapshot_with_files "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400 home/user
    ln -s -- /etc/hostname "$BACKUP_ROOT/$TEST_HOSTNAME/.accept-empty-sources"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'Error: /home/user has no files now' || return
}

test_empty_check_skipped_for_remote_host() {
    write_config remote-host 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=2'
    snapshot_with_files remote-host 2026-07-02_10:00:00_hourly 1782986400 home/someone
    export SUDO_USER=alice
    run_backup remote-host
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_contains "$RUN_OUTPUT" 'has no files now' || return
}

# --- commands that fail or misbehave ------------------------------------------

# A complete snapshot whose marker records the given epoch.
snapshot_at() {
    local host=$1 name=$2 epoch=$3
    mkdir -p -- "$BACKUP_ROOT/$host/$name"
    printf 'snapshot_epoch=%s\n' "$epoch" >"$BACKUP_ROOT/$host/$name/.complete"
}

real_command() {
    PATH=/usr/bin:/bin command -v "$1"
}

test_failing_sort_and_awk_cannot_cost_backups() {
    # Found by fault injection: one failed sort made a run delete a backup that
    # retention wanted to keep. The script must not depend on them at all.
    local cmd name
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    for cmd in sort awk; do
        printf '#!/bin/bash\nexit 1\n' >"$TEST_BIN/$cmd"
        chmod +x -- "$TEST_BIN/$cmd"
    done
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    for name in 2026-07-02_09:00:00_hourly 2026-07-02_10:00:00_hourly 2026-07-02_11:00:00_hourly \
        2026-07-02_12:00:00_hourly; do
        assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/$name/.complete" || return
    done
}

test_marker_time_must_match_the_name() {
    # A truncated marker (here 1970) must not make a backup look old enough to prune.
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 17
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_11:00:00_hourly/.complete" || return
    assert_file_not_contains "$TEST_STATE/rsync.calls" '--link-dest' || return
}

test_clock_behind_newest_backup_is_refused() {
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_13:00:00_hourly 1782997200 # an hour from "now"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'the clock is behind the newest backup 2026-07-02_13:00:00_hourly' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/.latest.incomplete" || return
}

test_clock_jump_that_would_prune_most_backups_is_refused() {
    local name
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    local -x TEST_NOW=$((TEST_NOW + 365 * 86400)) # the clock jumped a year ahead
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'retention would delete 3 of 4 backups at once' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    for name in 2026-07-02_09:00:00_hourly 2026-07-02_10:00:00_hourly 2026-07-02_11:00:00_hourly; do
        assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/$name/.complete" || return
    done
}

test_large_prune_can_be_accepted_once() {
    local host_dir=$BACKUP_ROOT/$TEST_HOSTNAME
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    snapshot_at "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    : >"$host_dir/.accept-large-prune"
    local -x TEST_NOW=$((TEST_NOW + 365 * 86400))
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_contains "$RUN_OUTPUT" 'Warning: deleting 3 of 4 backups because' || return
    assert_not_exists "$host_dir/2026-07-02_10:00:00_hourly" || return
    assert_exists "$host_dir/2027-07-02_12:00:00_hourly/.complete" || return
    assert_not_exists "$host_dir/.accept-large-prune" || return
}

test_cleanup_stops_when_deleting_frees_nothing() {
    local hour remaining
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=1'
    for hour in 05 06 07 08 09 10; do
        snapshot "$TEST_HOSTNAME" "2026-07-02_$hour:00:00_hourly" 1782993600
    done
    printf '1000000 5000\n' >"$TEST_STATE/df.plan" # low, and deleting never changes it
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'the last 3 deleted backups freed no space' || return
    remaining=$(find "$BACKUP_ROOT/$TEST_HOSTNAME" -maxdepth 1 -name '2026-07-02_*' | wc -l)
    assert_eq "$remaining" 3 || return
}

test_failed_connection_on_full_drive_deletes_nothing() {
    local hour
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=1'
    for hour in 07 08 09; do snapshot "$TEST_HOSTNAME" "2026-07-02_$hour:00:00_hourly" 1782993600; done
    printf '1000000 5000\n' >"$TEST_STATE/df.plan"
    printf '255|ssh: connect to host port 22: Connection refused\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 255 || return
    for hour in 07 08 09; do assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_$hour:00:00_hourly" || return; done
}

test_write_error_on_full_drive_counts_as_space_problem() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_07:00:00_hourly 1782975600
    snapshot "$TEST_HOSTNAME" 2026-07-02_08:00:00_hourly 1782979200
    printf '1000000 5000\n2000000 5000\n' >"$TEST_STATE/df.plan"
    printf '11|rsync: write failed on "x": Input/output error\n0|\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_07:00:00_hourly" || return
    assert_eq "$(<"$TEST_STATE/rsync.count")" 2 || return
}

test_pending_deletion_of_btrfs_snapshot_uses_btrfs() {
    local deleting=$BACKUP_ROOT/$TEST_HOSTNAME/.deleting-2026-07-02_10:00:00_hourly-1234
    use_btrfs
    mkdir -p -- "$deleting"
    : >"$deleting/.complete"
    : >"$deleting/.test-subvolume"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$deleting" || return
    assert_file_contains "$TEST_STATE/btrfs.calls" "subvolume delete $deleting" || return
}

test_pending_deletion_that_fails_does_not_block_backups() {
    local deleting=$BACKUP_ROOT/$TEST_HOSTNAME/.deleting-2026-07-02_10:00:00_hourly-1234
    mkdir -p -- "$deleting"
    : >"$deleting/.complete"
    cat >"$TEST_BIN/rm" <<'EOF'
#!/bin/bash
for arg; do
    [[ $arg == *.deleting-* ]] && { echo "rm: cannot remove '$arg': Input/output error" >&2; exit 1; }
done
exec "$(PATH=/usr/bin:/bin command -v rm)" "$@"
EOF
    chmod +x -- "$TEST_BIN/rm"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_contains "$RUN_OUTPUT" "could not finish removing $deleting" || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/.complete" || return
}

test_stat_failure_never_renames_a_btrfs_snapshot() {
    local host_dir=$BACKUP_ROOT/$TEST_HOSTNAME
    use_btrfs
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    subvolume_snapshot "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    cat >"$TEST_BIN/stat" <<'EOF'
#!/bin/bash
if [[ $1 == -f && $2 == -c && $3 == %T ]]; then printf 'btrfs\n'; exit 0; fi
if [[ $1 == -c && $2 == %i && $3 == -- ]]; then
    [[ $4 == *2026-07-02_09:00:00_hourly ]] && { echo "stat: Input/output error" >&2; exit 1; }
    [[ -e $4/.test-subvolume ]] && { printf '256\n'; exit 0; }
fi
exec "$REAL_STAT" "$@"
EOF
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'cannot read the inode number of' || return
    assert_exists "$host_dir/2026-07-02_09:00:00_hourly/.complete" || return
    assert_eq "$(pending_deletions)" 0 || return
}

test_unreadable_last_backup_stops_the_run() {
    snapshot_with_files "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400 etc
    cat >"$TEST_BIN/find" <<'EOF'
#!/bin/bash
[[ $1 == */2026-07-02_10:00:00_hourly/etc ]] && { echo "find: Input/output error" >&2; exit 1; }
exec "$(PATH=/usr/bin:/bin command -v find)" "$@"
EOF
    chmod +x -- "$TEST_BIN/find"
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'cannot read directory' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

test_backup_btrfs_did_not_create_is_reported() {
    use_btrfs
    export TEST_BTRFS_NOOP_ON='subvolume snapshot' # claims success, does nothing
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'the new backup is missing or incomplete' || return
}

test_hostname_is_read_once() {
    cat >"$TEST_BIN/hostname" <<'EOF'
#!/bin/bash
count=0
[[ -f $TEST_STATE/hostname.count ]] && read -r count <"$TEST_STATE/hostname.count"
echo $((count + 1)) >"$TEST_STATE/hostname.count"
((count == 0)) && echo "$TEST_HOSTNAME" || echo some-other-name
EOF
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_eq "$(<"$TEST_STATE/hostname.count")" 1 || return
    assert_file_contains "$TEST_STATE/rsync.calls" '/home /etc' || return
    assert_file_not_contains "$TEST_STATE/rsync.calls" 'ssh' || return
}

test_stale_rsync_temp_files_are_removed() {
    : >"$LOG_DIR/backup.sh.$TEST_HOSTNAME.rsync.AbC123"
    : >"$LOG_DIR/backup.sh.other-host.rsync.XyZ789"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_exists "$LOG_DIR/backup.sh.$TEST_HOSTNAME.rsync.AbC123" || return
    assert_exists "$LOG_DIR/backup.sh.other-host.rsync.XyZ789" || return
}

run_test() {
    local name=$1 fn=$2 rc

    setup
    "$fn"
    rc=$?
    teardown

    case $rc in
        0) printf 'ok - %s\n' "$name"; ((++PASS)) ;;
        77) printf 'skip - %s\n' "$name"; ((++SKIP)) ;;
        *) printf 'not ok - %s\n' "$name"; ((++FAIL)) ;;
    esac
}

[[ -f $BACKUP_SCRIPT ]] || {
    echo "backup script not found: $BACKUP_SCRIPT" >&2
    exit 2
}

if ((UID != 0)) && ! unshare -Ur -- true 2>/dev/null; then
    echo 'rootless user namespaces are required to test the root-only execution path' >&2
    exit 2
fi

run_test 'sudo re-exec preserves explicit host' test_sudo_reexec_preserves_host
run_test 'wrong backup mount is rejected' test_rejects_wrong_mount
run_test 'wrong backup mount source is rejected' test_rejects_wrong_mount_source
run_test 'untrusted config is rejected' test_rejects_untrusted_config
run_test 'untrusted host directory is rejected' test_rejects_untrusted_host_directory
run_test 'invalid host input is rejected' test_rejects_invalid_host
run_test 'missing host directory is rejected' test_rejects_missing_host_directory
run_test 'lock contention stops before rsync' test_lock_contention_stops_before_rsync
run_test 'local success uses link-dest and rotates latest' test_local_success_uses_link_dest_and_rotates
test_cleanup_never_deletes_the_newest_backup() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 168")' 'MIN_PER_LABEL_WHEN_FULL=0'
    snapshot "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    printf '100 5000\n' >"$TEST_STATE/df.plan" # stays below the reserve whatever is deleted
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'no label has a backup to delete without going below MIN_PER_LABEL_WHEN_FULL=0' || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_11:00:00_hourly/.complete" || return
}

test_hardlink_never_recycles_the_newest_backup() {
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 3600 1")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    printf '23|connection reset by peer\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 23 || return
    assert_not_contains "$RUN_OUTPUT" 'Recycling due snapshot as staging' || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_11:00:00_hourly/.complete" || return
    # the next successful run replaces it as usual
    printf '0|\n' >"$TEST_STATE/rsync.plan"
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_12:00:00_hourly/.complete" || return
    assert_not_exists "$BACKUP_ROOT/$TEST_HOSTNAME/2026-07-02_11:00:00_hourly" || return
}

test_retention_intervals_take_units() {
    local host_dir=$BACKUP_ROOT/$TEST_HOSTNAME
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 1h 2")' 'MIN_PER_LABEL_WHEN_FULL=1'
    snapshot "$TEST_HOSTNAME" 2026-07-02_09:00:00_hourly 1782982800
    snapshot "$TEST_HOSTNAME" 2026-07-02_10:00:00_hourly 1782986400
    snapshot "$TEST_HOSTNAME" 2026-07-02_11:00:00_hourly 1782990000
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_eq "$(find "$host_dir" -maxdepth 1 -type d -name '*_hourly' | wc -l)" 2 || return
    # 1d is a day: a daily backup from 23 hours ago means the new one is hourly
    rm -rf -- "$host_dir"/20*
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 1h 168" "daily 1d 30")'
    snapshot "$TEST_HOSTNAME" 2026-07-01_13:00:00_daily 1782910800
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_exists "$host_dir/2026-07-02_12:00:00_hourly" || return
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 1x 2")'
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'invalid retention entry: hourly 1x 2' || return
}

test_free_space_reserve_takes_a_size() {
    write_config "$TEST_HOSTNAME" 'FREE_SPACE_RESERVE=10'
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'FREE_SPACE_RESERVE must be a size like 500M or 10G: 10' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
    # the drive has 2000000 KiB free: less than 2G (2097152 KiB), more than 1G
    write_config "$TEST_HOSTNAME" 'FREE_SPACE_RESERVE=2G'
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'Destination is below free-space reserve after rsync' || return
    write_config "$TEST_HOSTNAME" 'FREE_SPACE_RESERVE=1G'
    run_backup
    assert_eq "$RUN_STATUS" 0 || return
    assert_not_contains "$RUN_OUTPUT" 'below free-space reserve' || return
}

test_renamed_settings_are_refused() {
    write_config "$TEST_HOSTNAME" 'CONFIG=("hourly 3600 168")'
    run_backup
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'CONFIG was renamed to RETENTION' || return
    write_config "$TEST_HOSTNAME" 'MIN_FREE_SPACE=1000'
    run_backup
    assert_contains "$RUN_OUTPUT" 'MIN_FREE_SPACE was renamed to FREE_SPACE_RESERVE' || return
    write_config "$TEST_HOSTNAME" 'RETENTION=("hourly 1h 168")'
    export WORK_DIR=$BACKUP_ROOT
    run_backup
    unset WORK_DIR
    assert_eq "$RUN_STATUS" 1 || return
    assert_contains "$RUN_OUTPUT" 'WORK_DIR was renamed to BACKUP_ROOT' || return
    assert_not_exists "$TEST_STATE/rsync.count" || return
}

run_test 'log is rotated and successful run is timed' test_log_is_rotated_and_run_is_timed
run_test 'runtime directory modes are normalized' test_runtime_directory_modes_are_normalized
run_test 'failure log records status and runtime' test_failure_log_records_status_and_runtime
run_test 'remote backup builds SSH sources' test_remote_backup_builds_ssh_sources
run_test 'remote backup requires SUDO_USER' test_remote_backup_requires_sudo_user
run_test 'non-space rsync failure preserves incomplete latest' test_non_space_rsync_failure_keeps_latest
run_test 'backup-device I/O error preserves incomplete latest' test_backup_device_io_error_keeps_latest
run_test 'vanished source files still complete snapshot' test_vanished_source_files_complete_snapshot
run_test 'ENOSPC failure cleans oldest backup and retries' test_enospc_failure_cleans_oldest_and_retries
run_test 'low reserve after success cleans and retries' test_low_space_after_success_cleans_and_retries
run_test 'cleanup refuses to cross minimum backup count' test_cleanup_refuses_to_cross_minimum
run_test 'retention pruning keeps newest snapshots' test_retention_prunes_oldest_snapshots
run_test 'recycled snapshot removes files deleted from host' test_recycles_due_snapshot_as_staging
run_test 'failed recycled snapshot remains incomplete' test_recycled_snapshot_failure_remains_incomplete
run_test 'recycled vanished-source snapshot has no stale files' test_recycled_vanished_source_files_complete_without_stale_files
run_test 'existing staging is preserved while due snapshot is deleted' test_existing_staging_preserves_resume_and_deletes_due_snapshot
run_test 'existing staging marker is removed before failed resume' test_existing_staging_marker_is_removed_before_failed_resume
run_test 'resumed staging removes files deleted from host' test_resumed_staging_removes_files_deleted_from_host
run_test 'retention pruning removes expired snapshots for all labels' test_retention_prunes_expired_snapshots_for_all_labels
run_test 'first due retention interval is selected' test_selects_first_due_retention_interval
run_test 'invalid retention config fails without rotation' test_invalid_config_fails_without_rotation
run_test 'df failure aborts without deleting snapshots' test_df_failure_aborts_without_cleanup
run_test 'malformed df output aborts without cleanup' test_malformed_df_output_aborts_without_cleanup
run_test 'findmnt failure aborts before rsync' test_findmnt_failure_aborts_before_rsync
run_test 'unplugged backup disk aborts without publishing snapshot' test_unplugged_backup_disk_aborts_without_publishing_snapshot
run_test 'unsafe staging stops before rsync' test_unsafe_staging_stops_before_rsync
run_test 'unsafe staging marker stops before rsync' test_unsafe_staging_marker_stops_before_rsync
run_test 'incomplete staging directory is resumed' test_incomplete_staging_is_resumed
run_test 'pending deletion is finalized before rsync' test_pending_deletion_is_finalized_before_rsync
run_test 'markerless pending deletion stops before rsync' test_markerless_pending_deletion_stops_before_rsync
run_test 'invalid pending deletion marker stops before rsync' test_invalid_pending_deletion_marker_stops_before_rsync
run_test 'unsafe pending deletion stops before rsync' test_unsafe_pending_deletion_stops_before_rsync
run_test 'snapshot collision cannot nest staging' test_snapshot_collision_does_not_nest_staging
run_test 'legacy snapshot is marked complete and reused' test_legacy_snapshot_is_marked_and_reused
run_test 'previous snapshot selection uses timestamp name' test_previous_snapshot_uses_name_not_mtime
run_test 'unmarked snapshot is ignored when legacy trust is disabled' test_unmarked_snapshot_is_ignored_when_legacy_trust_disabled
run_test 'invalid snapshot marker is ignored' test_invalid_snapshot_marker_is_ignored
run_test 'symlinked snapshot marker is ignored' test_symlinked_snapshot_marker_is_ignored
run_test 'exact retention boundary selects next interval' test_exact_retention_boundary_selects_next_interval
run_test 'emergency cleanup prefers shortest interval' test_emergency_cleanup_prefers_shortest_interval

run_test 'unsupported filesystem is rejected' test_unsupported_filesystem_is_rejected
run_test 'xfs uses hardlink mode' test_xfs_uses_hardlink_mode
run_test 'hardlink mode never calls btrfs' test_hardlink_mode_never_calls_btrfs
run_test 'filesystem change during run aborts without publishing' test_filesystem_change_during_run_aborts_without_publishing
run_test 'rsync never copies ACLs or xattrs' test_rsync_never_copies_acls_or_xattrs
run_test 'rsync compares timestamps to the nanosecond' test_rsync_compares_timestamps_to_the_nanosecond
run_test 'low free inodes after success cleans and retries' test_low_inodes_after_success_cleans_and_retries
run_test 'excludes are passed to rsync with --delete-excluded' test_excludes_are_passed_to_rsync
run_test 'no excludes by default' test_no_excludes_by_default
run_test 'empty exclude pattern is rejected' test_empty_exclude_pattern_is_rejected
run_test 'btrfs: snapshot of persistent staging subvolume' test_btrfs_snapshots_persistent_staging_subvolume
run_test 'btrfs: next run reuses staging subvolume' test_btrfs_next_run_reuses_staging
run_test 'btrfs: retention deletes subvolumes without waiting' test_btrfs_retention_deletes_subvolumes_without_waiting
run_test 'btrfs: low-space cleanup waits for reclaim before retry' test_btrfs_low_space_cleanup_waits_for_reclaim
run_test 'btrfs: ENOSPC cleans, waits for reclaim, retries' test_btrfs_enospc_cleans_waits_and_retries
run_test 'btrfs: missing inode count is not treated as full' test_btrfs_ignores_missing_inode_count
run_test 'btrfs: default free-space reserve is 10 GiB' test_btrfs_default_reserve_is_10_gib
run_test 'btrfs: free-space reserve can be overridden' test_btrfs_reserve_can_be_overridden
run_test 'btrfs: plain-directory snapshot is removed without btrfs' test_btrfs_plain_directory_snapshot_is_removed_without_btrfs
run_test 'btrfs: legacy plain directory is marked complete' test_btrfs_legacy_plain_directory_is_marked
run_test 'btrfs: markerless subvolume is left alone' test_btrfs_markerless_subvolume_is_left_alone
run_test 'btrfs: staging must be a subvolume' test_btrfs_staging_must_be_a_subvolume
run_test 'btrfs: rsync failure keeps staging without snapshot' test_btrfs_rsync_failure_keeps_staging_without_snapshot
run_test 'btrfs: failed snapshot is retried cleanly' test_btrfs_failed_snapshot_is_retried_cleanly
run_test 'btrfs: snapshot collision stops before staging' test_btrfs_snapshot_collision_stops_before_staging
run_test 'zfs source: each dataset copied from one atomic snapshot' test_zfs_source_copies_each_dataset_from_one_snapshot
run_test 'zfs source: snapshot destroyed when rsync fails' test_zfs_source_snapshot_is_destroyed_when_rsync_fails
run_test 'zfs source: failed snapshot stops before rsync' test_zfs_source_failed_snapshot_stops_before_rsync
run_test 'zfs source: stale snapshots destroyed first, others untouched' test_zfs_source_stale_snapshots_are_destroyed_first
run_test 'zfs source: ENOSPC retry reuses the same snapshot' test_zfs_source_enospc_retry_reuses_snapshot
run_test 'zfs source: hardlink mode links each tree to the previous one' test_zfs_source_link_dest_per_tree
run_test 'zfs source: works with a btrfs backup drive' test_zfs_source_with_btrfs_backup_drive
run_test 'zfs source: excludes apply to every tree' test_zfs_source_excludes_apply_to_every_tree
run_test 'zfs source: non-ZFS mount is copied live' test_zfs_source_non_zfs_mount_is_copied_live
run_test 'zfs source: escaped mount points are decoded' test_zfs_source_decodes_escaped_mount_points
run_test 'zfs source: bind mount of a dataset subdirectory is copied live' test_zfs_source_bind_mount_is_copied_live
run_test 'zfs source: wildcards in mount points are rejected' test_zfs_source_rejects_wildcards_in_mount_points
run_test 'zfs source: ignored for a remote host' test_zfs_source_ignored_for_remote_host
run_test 'no ZFS means one live rsync' test_no_zfs_means_one_live_rsync
run_test 'zfs source: zfs command is required' test_zfs_source_requires_zfs_command
run_test 'anchored exclude pattern is rejected' test_anchored_exclude_pattern_is_rejected
run_test 'unreadable mount table stops before rsync' test_unreadable_mount_table_stops_before_rsync
run_test 'empty check: home missing from its snapshot is refused' test_empty_check_refuses_home_missing_from_snapshot
run_test 'empty check: unmounted home dataset is refused' test_empty_check_refuses_unmounted_home_dataset
run_test 'empty check: missing home is refused without ZFS too' test_empty_check_refuses_missing_home_without_zfs
run_test 'empty check: looks at the snapshot, not the live files' test_empty_check_looks_at_the_snapshot_not_live_files
run_test 'empty check: passes when sources have files' test_empty_check_passes_when_sources_have_files
run_test 'empty check: ignores dirs already empty in the last backup' test_empty_check_ignores_dirs_empty_in_last_backup
run_test 'empty check: refusal leaves btrfs staging untouched' test_empty_check_leaves_btrfs_staging_untouched
run_test 'empty check: accept file allows one empty backup' test_accept_file_allows_one_empty_backup
run_test 'empty check: accept file survives a failed backup' test_accept_file_survives_a_failed_backup
run_test 'empty check: symlinked accept file is ignored' test_symlinked_accept_file_is_ignored
run_test 'empty check: skipped for a remote host' test_empty_check_skipped_for_remote_host
run_test 'failing sort and awk cannot cost backups' test_failing_sort_and_awk_cannot_cost_backups
run_test 'marker time must match the name' test_marker_time_must_match_the_name
run_test 'clock behind the newest backup is refused' test_clock_behind_newest_backup_is_refused
run_test 'clock jump that would prune most backups is refused' test_clock_jump_that_would_prune_most_backups_is_refused
run_test 'large prune can be accepted once' test_large_prune_can_be_accepted_once
run_test 'cleanup stops when deleting frees nothing' test_cleanup_stops_when_deleting_frees_nothing
run_test 'failed connection on a full drive deletes nothing' test_failed_connection_on_full_drive_deletes_nothing
run_test 'write error on a full drive counts as a space problem' test_write_error_on_full_drive_counts_as_space_problem
run_test 'pending deletion of a btrfs snapshot uses btrfs' test_pending_deletion_of_btrfs_snapshot_uses_btrfs
run_test 'pending deletion that fails does not block backups' test_pending_deletion_that_fails_does_not_block_backups
run_test 'stat failure never renames a btrfs snapshot' test_stat_failure_never_renames_a_btrfs_snapshot
run_test 'unreadable last backup stops the run' test_unreadable_last_backup_stops_the_run
run_test 'backup that btrfs did not create is reported' test_backup_btrfs_did_not_create_is_reported
run_test 'hostname is read once' test_hostname_is_read_once
run_test 'stale rsync temp files are removed' test_stale_rsync_temp_files_are_removed
run_test 'cleanup never deletes the newest backup' test_cleanup_never_deletes_the_newest_backup
run_test 'hardlink mode never recycles the newest backup' test_hardlink_never_recycles_the_newest_backup
run_test 'retention intervals take units' test_retention_intervals_take_units
run_test 'free-space reserve takes a size' test_free_space_reserve_takes_a_size
run_test 'renamed settings are refused' test_renamed_settings_are_refused

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0))
