#!/bin/bash
#
# Snapshot backups of /home and /etc onto an external drive.
#
# How backups are made depends on the backup drive's filesystem:
#   btrfs            rsync into a persistent staging subvolume (<host>/.staging),
#                    then take a read-only btrfs snapshot of it. Deleting an old
#                    backup is instant and its space is freed in the background.
#   ext4, ext3, xfs  rsync --link-dest into a staging directory that is then moved
#                    into place, so unchanged files are hardlinks between backups.
# Backups are named <UTC date>_<UTC time>_<label> and carry a .complete marker.
# On btrfs, backups that are plain directories (for example history copied over
# from an ext4 drive) are still pruned, the slow way with rm -rf.
#
# When /home or /etc is on ZFS (local backups only), the run first takes a ZFS
# snapshot of the datasets involved, all in one atomic command, copies from that
# snapshot instead of the live files, and destroys it once the copy is done. Each
# mount below /home and /etc is copied by its own rsync pass: from the snapshot if
# it is a ZFS dataset, live otherwise. Without ZFS, /home and /etc are copied live
# in a single rsync.
#
# Before copying, the run checks that nothing which had files in the last backup
# (/home, /etc, each copied tree, each home directory) is empty or missing now:
# that usually means an unmounted or locked filesystem, and backing it up would
# publish an empty copy. A run refuses then. To accept a real emptying once, create
# <host>/.accept-empty-sources; it is removed after the next successful backup.
#
# Other safety rules: a run refuses if the clock is behind the newest backup, or
# if retention would delete more than half of all backups at once (what a clock
# jump looks like; accept a real one with <host>/.accept-large-prune). Freeing
# space stops after 3 deleted backups in a row free nothing, and only rsync
# failures that look like a full drive ever lead to deleting backups.
#
# Words used below:
#   backup    a finished copy in <host dir>: a directory (or btrfs snapshot) named
#             as above, with a .complete marker whose epoch matches the name
#   label     a backup's retention class from RETENTION (hourly, daily, ...)
#   staging   where the next backup is assembled before it is published
#   tree      a directory copied by one rsync pass (with ZFS, each mount below
#             /home and /etc is a tree)
#
# A run, in order (the main part is at the end of this file):
#   1. checks: lock, the backup drive is mounted where expected, configuration
#   2. tidies up after earlier runs and reads the list of backups
#   3. picks the new backup's label; refuses if the clock or retention look wrong
#   4. with ZFS, snapshots the datasets; refuses if a source looks emptied
#   5. copies into staging, deleting the oldest backups if the drive is full
#   6. publishes staging as the new backup and applies retention
#
# One-time setup of a btrfs drive (as root):
#   mkfs.btrfs -L backup /dev/mapper/<name>
#   mount -o noatime,compress=zstd /dev/mapper/<name> <mount point>
#   install -d -m 0755 <mount point>/<host>

set -euo pipefail
shopt -s nullglob

die() {
    echo "Error: $*" >&2
    exit 1
}

warn() {
    echo "Warning: $*" >&2
}

LOCAL_HOST=$(hostname -s) || die "cannot determine this machine's host name"
[[ $LOCAL_HOST =~ ^[A-Za-z0-9.-]+$ ]] || die "unexpected host name from hostname -s: $LOCAL_HOST"
HOST=${1:-$LOCAL_HOST}
SCRIPT=$(readlink -f -- "$0")
SCRIPT_NAME=${SCRIPT##*/}

[[ $HOST =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid host name: $HOST"
# A renamed setting must never be silently ignored (see also validate_config).
[[ -z ${WORK_DIR+set} ]] || die "WORK_DIR was renamed to BACKUP_ROOT"

((UID != 0)) && exec sudo \
    --preserve-env=BACKUP_ROOT,EXPECTED_MOUNT_POINT,EXPECTED_MOUNT_SOURCE \
    -- "$SCRIPT" "$HOST"

RUN_STARTED=$(date +%s)
[[ $RUN_STARTED =~ ^[0-9]+$ ]] || die "unexpected output from date: $RUN_STARTED"

# --- Settings for <host dir>/.config, a bash file that must be root-owned and not
# group- or world-writable. The values here are the defaults.

# Retention classes, "label interval keep". A new backup gets the longest-interval
# label that is due (its newest backup is older than the interval), otherwise the
# shortest. Each label keeps at most its newest <keep> backups, and none older
# than interval x keep (the newest backup of all is always kept). An interval is
# seconds, or a number with a unit: s, m, h, d or w.
RETENTION=(
    "hourly 1h 168"
    "daily 1d 180"
    "weekly 1w 104"
    "monthly 4w 52"
)
# Free space the drive must still have after a copy, as a size: 500M, 10G, 1T.
# Empty means 1G, or 10G on btrfs, which needs room for metadata. When a copy
# leaves less, or fails for lack of space, the oldest backups are deleted one at a
# time and the copy is done again.
FREE_SPACE_RESERVE=''
FREE_INODE_RESERVE=1000    # the same for inodes; not checked on btrfs, which makes them as needed
MIN_PER_LABEL_WHEN_FULL=24 # deleting for space never takes a label below this many backups
# rsync exclude patterns, e.g. (.cache/ .local/share/Trash/). With ZFS every dataset
# is copied as its own tree, so a pattern can't span a dataset boundary, and
# anchored patterns (starting with /) are rejected.
EXCLUDES=()
# Directories that look like backups but have no .complete marker were made by
# versions of this script that didn't write one. With 1 they are given a marker
# and kept as backups; with 0 they are left alone and not counted.
ADOPT_UNMARKED_BACKUPS=1

# --- Settings from the environment, needed before .config is read.
BACKUP_ROOT=${BACKUP_ROOT:-${SCRIPT%/*}} # one directory per host in it; by default where this script is
LOG_DIR=${LOG_DIR:-/var/log/backup-script}
LOCK_DIR=${LOCK_DIR:-/run/lock/backup-script}
MOUNTINFO=${MOUNTINFO:-/proc/self/mountinfo} # the mount table; replaceable for tests
# Also read by verify_backup_mount: EXPECTED_MOUNT_POINT, the mount BACKUP_ROOT
# must be on (by default BACKUP_ROOT itself), and EXPECTED_MOUNT_SOURCE, the
# device that must be mounted there (not checked if unset).

# --- Names on the backup drive.
COMPLETE_MARKER=.complete
HARDLINK_STAGING_NAME=.latest.incomplete
BTRFS_STAGING_NAME=.staging
ZFS_SNAPSHOT_PREFIX=backup-script
ACCEPT_EMPTY_FILE=.accept-empty-sources
ACCEPT_LARGE_PRUNE_FILE=.accept-large-prune

# --- State of this run.
MODE=           # btrfs or hardlink, from the backup drive's filesystem
BACKUP_FSTYPE=  # that filesystem, as first seen; it must not change during the run
STAGING=
NEW_EPOCH=      # the new backup's time; also "now" for every retention decision
NEW_LABEL=
NEW_BACKUP=     # the new backup's path
RECYCLE=        # hardlink mode: the backup reused as staging, if any
RSYNC_ERR=      # temporary file with rsync's error output
ZFS_SNAPSHOT_NAME=
ZFS_SNAPSHOTS_CREATED=0
ZFS_DATASETS=() # datasets to snapshot; empty means a plain live rsync
TREE_PATHS=()   # with ZFS: the trees to copy, parents before children
TREE_SOURCES=() # with ZFS: where each tree is read from
# RETENTION, parsed and sorted by interval (seconds), shortest first.
LABELS=() LABEL_INTERVALS=() LABEL_KEEP=()
declare -A LABEL_INDEX=() # label -> its index in those arrays
RESERVE_KIB=              # FREE_SPACE_RESERVE in KiB, as df reports free space
# The finished backups, oldest first (see scan_backups).
BACKUP_DIRS=() BACKUP_EPOCHS=() BACKUP_LABELS=()
# Retention's verdict (see plan_retention).
DOOMED=() DOOMED_BY_AGE=0
CLEANUP_STRIKES=0
FREE_KIB=
FREE_INODES=

on_btrfs() {
    [[ $MODE == btrfs ]]
}

# --- Ownership checks for paths the script trusts.

# Sets OWNER and MODE_BITS (octal) for path $1.
read_owner_and_mode() {
    read -r OWNER MODE_BITS < <(stat -c '%u %a' -- "$1") || die "cannot check ownership of $1"
}

# Creates the log or lock directory $1 if needed; it must be root-owned with mode $2.
prepare_root_dir() {
    local dir=$1 expected_mode=$2

    [[ $dir == /* && ! -L $dir ]] || die "unsafe runtime directory: $dir"
    install -d -m "$expected_mode" -- "$dir"
    read_owner_and_mode "$dir"
    ((OWNER == 0 && 8#$MODE_BITS == 8#$expected_mode)) ||
        die "runtime directory must be root-owned and mode $expected_mode: $dir"
}

# True when $1 is root-owned and not group- or world-writable.
root_controlled() {
    read_owner_and_mode "$1"
    ((OWNER == 0 && (8#$MODE_BITS & 022) == 0))
}

# --- Configuration.

# Settings that were renamed; using an old name must not be silently ignored.
RENAMED_SETTINGS=(CONFIG=RETENTION MIN_BACKUP_COUNT=MIN_PER_LABEL_WHEN_FULL
    MIN_FREE_SPACE=FREE_SPACE_RESERVE MIN_FREE_INODES=FREE_INODE_RESERVE
    TRUST_LEGACY_SNAPSHOTS=ADOPT_UNMARKED_BACKUPS)

# Checks the settings (after .config is read and the drive's mode is known),
# parses RETENTION into the LABEL arrays, shortest interval first, and works out
# RESERVE_KIB. Numbers are read as decimal even with leading zeros.
validate_config() {
    local renamed entry label interval keep extra unit pattern i

    for renamed in "${RENAMED_SETTINGS[@]}"; do
        ! declare -p "${renamed%%=*}" &>/dev/null ||
            die "${renamed%%=*} was renamed to ${renamed#*=}; please update $CONFIG_FILE"
    done

    ((${#RETENTION[@]} > 0)) || die "RETENTION has no entries"
    for entry in "${RETENTION[@]}"; do
        read -r label interval keep extra <<<"$entry"
        # The interval is matched last, so BASH_REMATCH holds its number and unit.
        [[ -z ${extra:-} && $label =~ ^[A-Za-z0-9.-]+$ && $keep =~ ^[0-9]+$ &&
            $interval =~ ^([0-9]+)([smhdw]?)$ ]] ||
            die "invalid retention entry: $entry"
        case ${BASH_REMATCH[2]} in
            m) unit=60 ;;
            h) unit=3600 ;;
            d) unit=86400 ;;
            w) unit=604800 ;;
            *) unit=1 ;;
        esac
        interval=$((10#${BASH_REMATCH[1]} * unit)) keep=$((10#$keep))
        ((interval > 0 && keep > 0)) || die "retention values must be positive: $entry"
        [[ -z ${LABEL_INDEX[$label]:-} ]] || die "duplicate retention label: $label"
        LABEL_INDEX[$label]=1
        # Insertion sort, stable for equal intervals. Done here rather than by an
        # external command, whose failure would look like an empty list.
        for ((i = ${#LABELS[@]}; i > 0; i--)); do
            ((LABEL_INTERVALS[i - 1] > interval)) || break
            LABELS[i]=${LABELS[i - 1]} LABEL_INTERVALS[i]=${LABEL_INTERVALS[i - 1]} LABEL_KEEP[i]=${LABEL_KEEP[i - 1]}
        done
        LABELS[i]=$label LABEL_INTERVALS[i]=$interval LABEL_KEEP[i]=$keep
    done
    for i in "${!LABELS[@]}"; do
        LABEL_INDEX[${LABELS[i]}]=$i
    done

    if [[ -z $FREE_SPACE_RESERVE ]]; then
        if on_btrfs; then FREE_SPACE_RESERVE=10G; else FREE_SPACE_RESERVE=1G; fi
    fi
    [[ $FREE_SPACE_RESERVE =~ ^([0-9]+)([KMGT])$ ]] ||
        die "FREE_SPACE_RESERVE must be a size like 500M or 10G: $FREE_SPACE_RESERVE"
    case ${BASH_REMATCH[2]} in
        K) RESERVE_KIB=$((10#${BASH_REMATCH[1]})) ;;
        M) RESERVE_KIB=$((10#${BASH_REMATCH[1]} * 1024)) ;;
        G) RESERVE_KIB=$((10#${BASH_REMATCH[1]} * 1024 ** 2)) ;;
        T) RESERVE_KIB=$((10#${BASH_REMATCH[1]} * 1024 ** 3)) ;;
    esac
    [[ $FREE_INODE_RESERVE =~ ^[0-9]+$ ]] || die "FREE_INODE_RESERVE must be a number: $FREE_INODE_RESERVE"
    [[ $MIN_PER_LABEL_WHEN_FULL =~ ^[0-9]+$ ]] ||
        die "MIN_PER_LABEL_WHEN_FULL must be a number: $MIN_PER_LABEL_WHEN_FULL"
    FREE_INODE_RESERVE=$((10#$FREE_INODE_RESERVE)) MIN_PER_LABEL_WHEN_FULL=$((10#$MIN_PER_LABEL_WHEN_FULL))
    [[ $ADOPT_UNMARKED_BACKUPS =~ ^[01]$ ]] || die "ADOPT_UNMARKED_BACKUPS must be 0 or 1: $ADOPT_UNMARKED_BACKUPS"
    for pattern in "${EXCLUDES[@]}"; do
        [[ $pattern ]] || die "empty pattern in EXCLUDES"
        [[ $pattern != /* ]] || die "EXCLUDES patterns must not start with /: $pattern"
    done
}

# --- The backup drive.

# Checks that BACKUP_ROOT is on the expected mount (and source); called before and
# after every step that writes, so an unplugged or swapped drive stops the run.
verify_backup_mount() {
    local expected mount_info fstype target source

    expected=${EXPECTED_MOUNT_POINT:-$BACKUP_ROOT}
    expected=$(readlink -e -- "$expected") || die "expected mount point doesn't exist: $expected"
    mount_info=$(findmnt -n -o FSTYPE,TARGET --target "$BACKUP_ROOT") ||
        die "cannot determine filesystem mount for $BACKUP_ROOT"
    read -r fstype target <<<"$mount_info"
    [[ ${fstype:-} && ${target:-} ]] || die "cannot determine filesystem mount for $BACKUP_ROOT"
    target=$(readlink -e -- "$target") || die "cannot resolve mount target: $target"
    [[ $target == "$expected" ]] ||
        die "BACKUP_ROOT is on mount $target, expected $expected"

    # The filesystem type decides how backups are made, so it is recorded by
    # the first check and must not change for the rest of the run.
    [[ -z $BACKUP_FSTYPE || $fstype == "$BACKUP_FSTYPE" ]] ||
        die "filesystem of $BACKUP_ROOT changed from $BACKUP_FSTYPE to $fstype"
    BACKUP_FSTYPE=$fstype

    [[ -z ${EXPECTED_MOUNT_SOURCE:-} ]] && return 0
    source=$(findmnt -n -o SOURCE --target "$BACKUP_ROOT") ||
        die "cannot determine filesystem source for $BACKUP_ROOT"
    [[ $source == "$EXPECTED_MOUNT_SOURCE" ]] ||
        die "BACKUP_ROOT source is $source, expected $EXPECTED_MOUNT_SOURCE"
}

# Picks how backups are made from the filesystem verify_backup_mount recorded.
# Anything not listed here is refused rather than guessed at.
select_mode() {
    case $BACKUP_FSTYPE in
        btrfs)
            MODE=btrfs
            STAGING=${HOST_DIR}/${BTRFS_STAGING_NAME}
            command -v btrfs >/dev/null || die "btrfs is required"
            ;;
        ext4 | ext3 | xfs)
            MODE=hardlink
            STAGING=${HOST_DIR}/${HARDLINK_STAGING_NAME}
            ;;
        *)
            die "unsupported filesystem on backup drive: $BACKUP_FSTYPE"
            ;;
    esac
    echo "Backup mode: $MODE ($BACKUP_FSTYPE)"
}

# A btrfs subvolume's root directory always has inode number 256.
is_subvolume() {
    local fstype inode

    [[ -d $1 && ! -L $1 ]] || return 1
    fstype=$(stat -f -c %T -- "$1") || die "cannot read the filesystem type of $1"
    inode=$(stat -c %i -- "$1") || die "cannot read the inode number of $1"
    [[ $fstype == btrfs && $inode == 256 ]]
}

# --- Recognizing backups. These set variables instead of printing, so they run
# in this shell: no subshell per backup, and a die really stops the run.

# Splits a backup name <YYYY-MM-DD>_<HH:MM:SS>_<label> into NAME_TIME and
# NAME_LABEL; fails unless it is one and its label is one RETENTION manages.
parse_backup_name() {
    [[ $1 =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}:[0-9]{2})_([A-Za-z0-9.-]+)$ ]] || return 1
    NAME_TIME=${BASH_REMATCH[1]} NAME_LABEL=${BASH_REMATCH[2]}
    [[ -n ${LABEL_INDEX[$NAME_LABEL]:-} ]]
}

# Sets MARKER_EPOCH to the snapshot_epoch in marker file $1, empty if it has none.
# Builtins only, so no command failure can turn into a wrong answer.
marker_epoch() {
    local line

    MARKER_EPOCH=
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == snapshot_epoch=* ]]; then
            MARKER_EPOCH=${line#snapshot_epoch=}
        fi
    done <"$1" || return 1
}

# Sets EPOCH from NAME_TIME read as local time, which is how names were written
# before markers recorded the epoch.
legacy_name_epoch() {
    EPOCH=$(date -d "${NAME_TIME/_/ }" +%s) && [[ $EPOCH =~ ^[0-9]+$ ]]
}

# Succeeds if $1 is a finished backup, setting EPOCH to its time and NAME_LABEL to
# its label: a real directory with a backup name and a regular .complete marker
# whose epoch agrees with the name (UTC, or local time for migrated legacy
# backups). A damaged or truncated marker must never make a backup look older
# than it is, or retention would delete it.
backup_epoch() {
    local dir=$1 marker=$1/$COMPLETE_MARKER utc local_time

    EPOCH=
    [[ -d $dir && ! -L $dir && -f $marker && ! -L $marker ]] || return 1
    parse_backup_name "${dir##*/}" || return 1
    marker_epoch "$marker" || return 1
    [[ $MARKER_EPOCH ]] || {
        legacy_name_epoch
        return
    }
    [[ $MARKER_EPOCH =~ ^[0-9]{1,12}$ ]] || return 1
    TZ=UTC0 printf -v utc '%(%F_%T)T' "$MARKER_EPOCH"
    printf -v local_time '%(%F_%T)T' "$MARKER_EPOCH"
    [[ $utc == "$NAME_TIME" || $local_time == "$NAME_TIME" ]] || return 1
    EPOCH=$MARKER_EPOCH
}

# Lists the finished backups, oldest first, in BACKUP_DIRS, BACKUP_EPOCHS and
# BACKUP_LABELS. Anything that isn't a finished backup with a readable time is
# left out, so it is never counted, linked against or deleted. Every decision
# about backups works on this list; it is rescanned after anything changes.
scan_backups() {
    local dir i

    BACKUP_DIRS=() BACKUP_EPOCHS=() BACKUP_LABELS=()
    for dir in "$HOST_DIR"/????-??-??_??:??:??_*; do
        backup_epoch "$dir" || continue
        # Insertion by time. Names are UTC times, so the glob is already in
        # order and nothing moves, except around migrated local-time names.
        for ((i = ${#BACKUP_DIRS[@]}; i > 0; i--)); do
            ((BACKUP_EPOCHS[i - 1] > EPOCH)) || break
            BACKUP_DIRS[i]=${BACKUP_DIRS[i - 1]} BACKUP_EPOCHS[i]=${BACKUP_EPOCHS[i - 1]} BACKUP_LABELS[i]=${BACKUP_LABELS[i - 1]}
        done
        BACKUP_DIRS[i]=$dir BACKUP_EPOCHS[i]=$EPOCH BACKUP_LABELS[i]=$NAME_LABEL
    done
}

# Prints the newest backup; fails if there is none.
newest_backup() {
    ((${#BACKUP_DIRS[@]})) && printf '%s\n' "${BACKUP_DIRS[-1]}"
}

# --- Deleting backups.

# Deletes the tree $1: with btrfs subvolume delete if it is a subvolume (instant,
# space freed in the background), otherwise with rm -rf.
delete_tree() {
    if on_btrfs && is_subvolume "$1"; then
        btrfs subvolume delete "$1"
    else
        nice rm -rf -- "$1"
    fi
}

# Deletes backup $1. A plain directory is first renamed out of the way, so an
# interrupted rm -rf never leaves a half-deleted backup that still looks complete;
# the next run finishes the job (finish_interrupted_deletions).
delete_backup() {
    local dir=$1 deleting

    backup_epoch "$dir" || die "refusing to remove unrecognized snapshot: $dir"
    if ! { on_btrfs && is_subvolume "$dir"; }; then
        deleting=${HOST_DIR}/.deleting-${dir##*/}-$$
        [[ ! -e $deleting ]] || die "temporary deletion path exists: $deleting"
        mv -T -- "$dir" "$deleting"
        dir=$deleting
    fi
    delete_tree "$dir"
}

# Finishes deletions an earlier run started (.deleting-<backup>-<pid>). They are
# checked to be what delete_backup leaves, so nothing else is ever deleted. A
# failure only warns: a stuck leftover must not stop new backups.
finish_interrupted_deletions() {
    local dir name

    for dir in "$HOST_DIR"/.deleting-*; do
        [[ -d $dir && ! -L $dir ]] || die "unsafe pending deletion path: $dir"
        [[ ${dir##*/} =~ ^\.deleting-(.+)-[0-9]+$ ]] ||
            die "unrecognized pending deletion path: $dir"
        name=${BASH_REMATCH[1]}
        [[ -f $dir/$COMPLETE_MARKER && ! -L $dir/$COMPLETE_MARKER ]] ||
            die "pending deletion is missing a regular completion marker: $dir"
        marker_epoch "$dir/$COMPLETE_MARKER" || die "cannot read $dir/$COMPLETE_MARKER"
        [[ -z $MARKER_EPOCH || $MARKER_EPOCH =~ ^[0-9]+$ ]] ||
            die "pending deletion has an invalid completion marker: $dir"
        parse_backup_name "$name" || die "unrecognized pending deletion snapshot: $dir"
        echo "Finalizing interrupted cleanup: $dir"
        delete_tree "$dir" || warn "could not finish removing $dir; will try again next run"
    done
}

# Gives markers to backups made by versions of this script that didn't write any
# (see ADOPT_UNMARKED_BACKUPS). Their names are in local time.
mark_legacy_backups_complete() {
    local dir

    ((ADOPT_UNMARKED_BACKUPS)) || return 0
    for dir in "$HOST_DIR"/????-??-??_??:??:??_*; do
        [[ -d $dir && ! -L $dir && ! -e $dir/$COMPLETE_MARKER ]] || continue
        # This script never makes a btrfs snapshot without a marker, and a
        # read-only snapshot can't be given one, so leave such a snapshot alone.
        if on_btrfs && is_subvolume "$dir"; then
            warn "ignoring btrfs snapshot without a completion marker: $dir"
            continue
        fi
        { parse_backup_name "${dir##*/}" && legacy_name_epoch; } || continue
        echo "Marking legacy snapshot complete: $dir"
        # Written aside and renamed, so a crash or full disk never leaves a
        # truncated marker in a published backup.
        printf 'snapshot_epoch=%s\nlegacy_local_time=%s\n' "$EPOCH" "${dir##*/}" >"$dir/$COMPLETE_MARKER.tmp"
        mv -f -- "$dir/$COMPLETE_MARKER.tmp" "$dir/$COMPLETE_MARKER"
    done
}

# --- Retention.

# Sets NEW_LABEL: the longest-interval label whose newest backup is older than
# its interval, or the shortest label if none is due.
choose_label() {
    local c i last_epoch

    for ((c = ${#LABELS[@]} - 1; c >= 0; c--)); do
        last_epoch=0 # of this label's newest backup; the list is oldest first
        for i in "${!BACKUP_DIRS[@]}"; do
            [[ ${BACKUP_LABELS[i]} == "${LABELS[c]}" ]] && last_epoch=${BACKUP_EPOCHS[i]}
        done
        if ((NEW_EPOCH - last_epoch > LABEL_INTERVALS[c])); then
            NEW_LABEL=${LABELS[c]}
            return
        fi
    done
    NEW_LABEL=${LABELS[0]}
}

# Works out what retention deletes at time $1, into DOOMED (label by label,
# newest first). Per label, backups beyond the count to keep are deleted by rank;
# those within it but older than interval x count are deleted by age, and counted
# in DOOMED_BY_AGE. With $2, a new backup of that label is counted as already
# taken, and is then the newest; without it the newest backup is kept. The
# backup $3 is always kept.
plan_retention() {
    local now=$1 new_label=${2:-} protect=${3:-} newest='' c i rank cutoff

    DOOMED=() DOOMED_BY_AGE=0
    # Once a new backup is counted, it is the newest; the current newest is not.
    [[ $new_label ]] || newest=$(newest_backup || :)
    for c in "${!LABELS[@]}"; do
        cutoff=$((now - LABEL_INTERVALS[c] * LABEL_KEEP[c]))
        rank=0
        [[ ${LABELS[c]} == "$new_label" ]] && rank=1
        for ((i = ${#BACKUP_DIRS[@]} - 1; i >= 0; i--)); do
            [[ ${BACKUP_LABELS[i]} == "${LABELS[c]}" ]] || continue
            rank=$((rank + 1))
            [[ ${BACKUP_DIRS[i]} == "$newest" || ${BACKUP_DIRS[i]} == "$protect" ]] && continue
            if ((rank > LABEL_KEEP[c])); then
                DOOMED+=("${BACKUP_DIRS[i]}")
            elif ((BACKUP_EPOCHS[i] < cutoff)); then
                DOOMED+=("${BACKUP_DIRS[i]}")
                DOOMED_BY_AGE=$((DOOMED_BY_AGE + 1))
            fi
        done
    done
}

# Deleting more than half of all $1 backups because they look too old is what a
# clock that jumped forward looks like: every backup suddenly seems old. It is
# refused unless accepted once with the marker file. Deletions beyond the count
# to keep are the configuration at work and don't count.
check_prune_size() {
    local total=$1 accept=$HOST_DIR/$ACCEPT_LARGE_PRUNE_FILE

    ((DOOMED_BY_AGE * 2 <= total)) && return 0
    if [[ -f $accept && ! -L $accept ]]; then
        warn "deleting $DOOMED_BY_AGE of $total backups because $accept exists"
        return 0
    fi
    die "retention would delete $DOOMED_BY_AGE of $total backups at once because they look too old, which usually means the clock jumped forward; nothing was deleted. If it's expected (after a long break), run: touch $accept"
}

# Before anything is changed: the clock must not be behind the newest backup
# (the new backup would sort as the oldest and could be pruned at once), and
# retention must not be about to delete most of the backups.
check_clock_and_retention() {
    local newest

    if newest=$(newest_backup); then
        ((BACKUP_EPOCHS[-1] <= NEW_EPOCH)) ||
            die "the clock is behind the newest backup ${newest##*/}; fix the clock, or remove that backup if its time is wrong"
    fi
    plan_retention "$NEW_EPOCH" "$NEW_LABEL"
    check_prune_size $((${#BACKUP_DIRS[@]} + 1))
}

# Applies retention once the new backup is published.
prune_old_backups() {
    local dir

    scan_backups
    plan_retention "$NEW_EPOCH" "" "$NEW_BACKUP"
    check_prune_size "${#BACKUP_DIRS[@]}"
    for dir in "${DOOMED[@]}"; do
        delete_backup "$dir"
    done
    rm -f -- "$HOST_DIR/$ACCEPT_LARGE_PRUNE_FILE"
}

# --- Free space.

# Sets FREE_KIB and, except on btrfs, FREE_INODES; dies on anything odd.
read_free_space() {
    local fields=avail output line

    # btrfs allocates inodes dynamically and reports none, so only check space.
    on_btrfs || fields=avail,iavail
    output=$(df --block-size=1K --output="$fields" -- "$BACKUP_ROOT") ||
        die "failed to read free space for $BACKUP_ROOT"
    line=${output#*$'\n'}
    [[ $line != "$output" ]] || die "invalid free-space data for $BACKUP_ROOT"
    read -r FREE_KIB FREE_INODES <<<"$line"
    [[ ${FREE_KIB:-} =~ ^[0-9]+$ ]] || die "invalid free-space data for $BACKUP_ROOT"
    on_btrfs && return 0
    [[ ${FREE_INODES:-} =~ ^[0-9]+$ ]] || die "invalid free-inode data for $BACKUP_ROOT"
}

enough_free_space() {
    read_free_space
    ((FREE_KIB >= RESERVE_KIB)) || return 1
    on_btrfs && return 0
    ((FREE_INODES >= FREE_INODE_RESERVE))
}

# btrfs frees deleted data in the background. Wait for that before free space
# is checked again, or make_room deletes more backups than it needs to.
wait_for_freed_space() {
    on_btrfs || return 0
    btrfs subvolume sync "$HOST_DIR"
    btrfs filesystem sync "$HOST_DIR"
}

# Deletes one backup to make room: the oldest of the shortest-interval label that
# has more than MIN_PER_LABEL_WHEN_FULL backups, never the newest backup. If deleting
# backups frees nothing three times in a row, the space is used by something else
# or the numbers are wrong, and deleting more would only destroy history.
make_room() {
    local c i count oldest before_kib before_inodes newest

    newest=$(newest_backup || :)
    for c in "${!LABELS[@]}"; do
        count=0 oldest=
        for i in "${!BACKUP_DIRS[@]}"; do
            [[ ${BACKUP_LABELS[i]} == "${LABELS[c]}" ]] || continue
            count=$((count + 1))
            [[ $oldest ]] || oldest=${BACKUP_DIRS[i]}
        done
        ((count > MIN_PER_LABEL_WHEN_FULL)) && [[ $oldest != "$newest" ]] || continue
        read_free_space
        before_kib=$FREE_KIB before_inodes=${FREE_INODES:-0}
        echo "Cleanup: $oldest"
        delete_backup "$oldest"
        wait_for_freed_space
        scan_backups
        read_free_space
        if ((FREE_KIB > before_kib)) || { ! on_btrfs && ((FREE_INODES > before_inodes)); }; then
            CLEANUP_STRIKES=0
        elif ((++CLEANUP_STRIKES >= 3)); then
            die "the last 3 deleted backups freed no space; stopping cleanup so no more history is lost"
        fi
        return 0
    done
    die "the drive is full, and no label has a backup to delete without going below MIN_PER_LABEL_WHEN_FULL=$MIN_PER_LABEL_WHEN_FULL"
}

# True if a failed rsync ($1: its error output, $2: its exit code) looks like a
# full drive. rsync's own report decides. Without one, low free space only counts
# for exit codes of local write failures (11 file I/O, 12 data stream, 23
# partial); a connection or source problem must never make the run delete backups.
out_of_space_failure() {
    local err=$1 rc=$2

    grep -qiE 'No space left on device|Disk quota exceeded|ENOSPC' "$err" && return 0
    case $rc in
        11 | 12 | 23) ! enough_free_space ;;
        *) return 1 ;;
    esac
}

# --- What to copy from where.

# Loads the mount table. MOUNT_POINTS[i], MOUNT_ROOTS[i], MOUNT_FSTYPES[i] and
# MOUNT_SOURCES[i] describe one mount, in the kernel's order (later mounts last).
read_mounts() {
    local -a fields
    local i sep root point source

    MOUNT_POINTS=() MOUNT_ROOTS=() MOUNT_FSTYPES=() MOUNT_SOURCES=()
    [[ -r $MOUNTINFO ]] || die "cannot read mount table: $MOUNTINFO"
    while read -r -a fields; do
        # Optional fields run from field 7 to a lone "-"; fstype and source follow.
        sep=
        for ((i = 6; i < ${#fields[@]}; i++)); do
            if [[ ${fields[i]} == - ]]; then
                sep=$i
                break
            fi
        done
        if [[ -z $sep ]] || ((${#fields[@]} <= sep + 2)); then
            die "unexpected line in $MOUNTINFO: ${fields[*]}"
        fi
        # Paths are escaped as \040 (space), \011, \012 and \134 (backslash).
        printf -v root '%b' "${fields[3]}"
        printf -v point '%b' "${fields[4]}"
        printf -v source '%b' "${fields[sep + 2]}"
        MOUNT_ROOTS+=("$root")
        MOUNT_POINTS+=("$point")
        MOUNT_FSTYPES+=("${fields[sep + 1]}")
        MOUNT_SOURCES+=("$source")
    done <"$MOUNTINFO"
}

# Sets SORTED_PATHS to the given paths without duplicates, shortest first, so a
# directory always comes before anything below it. Pure bash: a failed sort
# command would otherwise look like an empty list.
sort_paths() {
    local path i
    declare -A seen=()

    SORTED_PATHS=()
    for path; do
        [[ -n ${seen[$path]:-} ]] && continue
        seen[$path]=1
        for ((i = ${#SORTED_PATHS[@]}; i > 0; i--)); do
            ((${#SORTED_PATHS[i - 1]} > ${#path})) ||
                { ((${#SORTED_PATHS[i - 1]} == ${#path})) && [[ ${SORTED_PATHS[i - 1]} > $path ]]; } || break
            SORTED_PATHS[i]=${SORTED_PATHS[i - 1]}
        done
        SORTED_PATHS[i]=$path
    done
}

# True when path $1 is the directory $2 or lies below it.
path_is_within() {
    [[ $2 == / || $1 == "$2" || $1 == "$2"/* ]]
}

# Prints the index of the entry of array $1 (a list of directories) that most
# closely holds path $2: the longest one it is within, and of equal ones the last
# (for mounts, the one stacked on top). Fails if none holds it.
closest_container() {
    local -n candidates=$1
    local path=$2 i best='' best_length=-1

    for i in "${!candidates[@]}"; do
        path_is_within "$path" "${candidates[i]}" || continue
        ((${#candidates[i]} >= best_length)) || continue
        best=$i best_length=${#candidates[i]}
    done
    [[ $best ]] && printf '%s\n' "$best"
}

# A whole ZFS dataset mounted normally: not a snapshot, not a bind of a subdirectory.
zfs_dataset_mount() {
    [[ ${MOUNT_FSTYPES[$1]} == zfs && ${MOUNT_SOURCES[$1]} != *@* && ${MOUNT_ROOTS[$1]} == / ]]
}

# Snapshots that ZFS mounts on access under .zfs/snapshot are not part of the data.
zfs_snapshot_mount() {
    [[ ${MOUNT_FSTYPES[$1]} == zfs && ${MOUNT_SOURCES[$1]} == *@* ]] || [[ ${MOUNT_POINTS[$1]} == */.zfs/* ]]
}

# Works out what to copy from where. When any part of /home or /etc is on ZFS,
# every mount below them becomes its own tree, read from the snapshot if it is a
# ZFS dataset and live otherwise (TREE_PATHS, TREE_SOURCES, ZFS_DATASETS). Without
# ZFS, and for remote hosts, all three stay empty and one plain rsync copies
# /home and /etc.
plan_trees() {
    local top path index dataset rel
    local -a paths=()
    declare -A datasets_seen=()

    ZFS_DATASETS=() TREE_PATHS=() TREE_SOURCES=()
    [[ $HOST == "$LOCAL_HOST" ]] || return 0
    read_mounts
    for top in /home /etc; do
        paths+=("$top")
        for index in "${!MOUNT_POINTS[@]}"; do
            [[ ${MOUNT_POINTS[index]} == "$top"/* ]] || continue
            zfs_snapshot_mount "$index" || paths+=("${MOUNT_POINTS[index]}")
        done
    done
    sort_paths "${paths[@]}"

    for path in "${SORTED_PATHS[@]}"; do
        index=$(closest_container MOUNT_POINTS "$path") || die "cannot find the mount that holds $path"
        TREE_PATHS+=("$path")
        if ! zfs_dataset_mount "$index"; then
            TREE_SOURCES+=("$path/")
            continue
        fi
        dataset=${MOUNT_SOURCES[index]}
        [[ -n ${datasets_seen[$dataset]:-} ]] || ZFS_DATASETS+=("$dataset")
        datasets_seen[$dataset]=1
        rel=${path#"${MOUNT_POINTS[index]%/}"}
        TREE_SOURCES+=("${MOUNT_POINTS[index]%/}/.zfs/snapshot/${ZFS_SNAPSHOT_NAME}${rel}/")
    done

    if ((${#ZFS_DATASETS[@]} == 0)); then
        TREE_PATHS=() TREE_SOURCES=()
        return 0
    fi
    for path in "${TREE_PATHS[@]}"; do
        # These paths end up in rsync filter rules, where they would be wildcards.
        [[ $path != *[][*?\\]* && $path != *$'\n'* ]] ||
            die "unsupported character in mount point: $path"
    done
    echo "/home or /etc is on ZFS; copying from snapshot @$ZFS_SNAPSHOT_NAME"
    for index in "${!TREE_PATHS[@]}"; do
        echo "  ${TREE_PATHS[index]} <- ${TREE_SOURCES[index]}"
    done
}

# True when $1 is a directory with at least one entry. Missing or not a directory
# counts as empty; a directory that can't be read stops the run, since guessing
# either way could publish an empty backup or skip the check.
dir_has_entries() {
    local first

    [[ -d $1 ]] || return 1
    first=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit) || die "cannot read directory $1"
    [[ -n $first ]]
}

# Where path $1 (somewhere under /home or /etc) is read from in this run.
source_path_of() {
    local path=$1 i

    if i=$(closest_container TREE_PATHS "$path"); then
        printf '%s\n' "${TREE_SOURCES[i]%/}${path#"${TREE_PATHS[i]}"}"
    else
        printf '%s\n' "$path"
    fi
}

# A tree that had files in the last backup but is empty or missing now is far
# more likely unmounted, locked or unreadable than really emptied. Backing it up
# would publish an empty copy, and once the files are back they would be copied
# again in full instead of being shared with the older backups.
check_sources_not_emptied() {
    local reference path accept=$HOST_DIR/$ACCEPT_EMPTY_FILE
    local -a paths=(/home /etc "${TREE_PATHS[@]}") empty=()

    [[ $HOST == "$LOCAL_HOST" ]] || return 0
    reference=$(newest_backup) || return 0
    for path in "$reference"/home/*; do
        [[ -d $path && ! -L $path ]] && paths+=("/home/${path##*/}")
    done
    sort_paths "${paths[@]}"
    for path in "${SORTED_PATHS[@]}"; do
        dir_has_entries "$reference$path" || continue
        dir_has_entries "$(source_path_of "$path")" || empty+=("$path")
    done
    ((${#empty[@]})) || return 0

    if [[ -f $accept && ! -L $accept ]]; then
        warn "backing up as empty because $accept exists: ${empty[*]}"
        return 0
    fi
    for path in "${empty[@]}"; do
        echo "Error: $path has no files now, but the last backup (${reference##*/}) has files there" >&2
    done
    die "refusing to back up what looks unmounted, locked or unreadable; if it really is empty now, run: touch $accept"
}

# --- ZFS snapshots of the sources.

# Only names this script creates: <dataset>@backup-script-<epoch>.
is_own_zfs_snapshot() {
    local pattern="^[A-Za-z0-9_.:/ -]+@${ZFS_SNAPSHOT_PREFIX}-[0-9]+\$"
    [[ $1 =~ $pattern ]]
}

destroy_zfs_snapshot() {
    zfs destroy "$1" || warn "could not destroy ZFS snapshot $1"
}

# Snapshots of ours that a killed run left behind.
destroy_stale_zfs_snapshots() {
    local dataset snapshot

    for dataset in "${ZFS_DATASETS[@]}"; do
        while IFS= read -r snapshot; do
            { [[ $snapshot == "$dataset@"* ]] && is_own_zfs_snapshot "$snapshot"; } || continue
            echo "Destroying ZFS snapshot left by an interrupted run: $snapshot"
            destroy_zfs_snapshot "$snapshot"
        done < <(zfs list -H -t snapshot -o name -d 1 "$dataset" || :)
    done
}

create_zfs_snapshots() {
    local dataset
    local -a snapshots=()

    for dataset in "${ZFS_DATASETS[@]}"; do
        snapshots+=("$dataset@$ZFS_SNAPSHOT_NAME")
    done
    # One command, so all datasets are captured at the same moment.
    zfs snapshot "${snapshots[@]}"
    ZFS_SNAPSHOTS_CREATED=1
}

# Called once the copy is done, and again by the exit trap; runs only once.
destroy_zfs_snapshots() {
    local dataset snapshot

    ((ZFS_SNAPSHOTS_CREATED)) || return 0
    ZFS_SNAPSHOTS_CREATED=0
    echo "Destroying ZFS snapshot @$ZFS_SNAPSHOT_NAME"
    for dataset in "${ZFS_DATASETS[@]}"; do
        snapshot=$dataset@$ZFS_SNAPSHOT_NAME
        if is_own_zfs_snapshot "$snapshot"; then
            destroy_zfs_snapshot "$snapshot"
        else
            warn "not destroying unexpected ZFS snapshot name: $snapshot"
        fi
    done
}

# --- Staging.

remove_staging_marker() {
    local marker=$STAGING/$COMPLETE_MARKER

    [[ -e $marker || -L $marker ]] || return 0
    [[ -f $marker && ! -L $marker ]] || die "unsafe staging marker: $marker"
    rm -- "$marker"
}

# Sets RECYCLE to the backup hardlink mode can reuse as staging: the oldest one
# with the new backup's label if retention is about to delete it anyway, never
# the newest backup. Recycling saves deleting it and re-linking unchanged files.
choose_recycled_backup() {
    local dir newest

    RECYCLE=
    newest=$(newest_backup || :)
    plan_retention "$NEW_EPOCH" "$NEW_LABEL"
    for dir in "${DOOMED[@]}"; do
        # DOOMED is newest first within each label, so the last match is the oldest.
        parse_backup_name "${dir##*/}" && [[ $NAME_LABEL == "$NEW_LABEL" ]] && RECYCLE=$dir
    done
    [[ $RECYCLE != "$newest" ]] || RECYCLE=
}

# Hardlink mode: staging is a directory that is moved into place as the new
# backup. An incomplete one left by a failed run is resumed; otherwise a backup
# that is due for deletion is recycled ($1), or a new directory is made.
prepare_hardlink_staging() {
    local recycle=$1

    if [[ -e $STAGING || -L $STAGING ]]; then
        [[ -d $STAGING && ! -L $STAGING ]] || die "unsafe staging path: $STAGING"
        chmod 0755 -- "$STAGING"
        remove_staging_marker
        echo "Resuming incomplete staging directory: $STAGING"
        [[ $recycle ]] || return 0
        echo "Cleanup: $recycle (preserving incomplete staging directory)"
        delete_backup "$recycle"
        return
    fi
    if [[ $recycle ]]; then
        echo "Recycling due snapshot as staging: $recycle"
        mv -T -- "$recycle" "$STAGING"
        rm -- "$STAGING/$COMPLETE_MARKER"
        return
    fi
    mkdir -m 0755 -- "$STAGING"
}

# btrfs mode: staging is a subvolume that persists between runs and always holds
# the latest copy, so each rsync only transfers what changed since the last run.
prepare_btrfs_staging() {
    if [[ -e $STAGING || -L $STAGING ]]; then
        is_subvolume "$STAGING" || die "staging path is not a btrfs subvolume: $STAGING"
    else
        btrfs subvolume create "$STAGING"
    fi
    chmod 0755 -- "$STAGING"
    remove_staging_marker
}

# --- Copying.

# One rsync run; its errors go to the log and to $1 for out_of_space_failure.
# Exit code 24 (files vanished during the transfer) is normal for live files.
rsync_pass() {
    local err=$1 rc
    shift

    : >"$err"
    nice rsync "$@" 2>"$err" || {
        rc=$?
        [[ ! -s $err ]] || cat -- "$err" >&2
        if ((rc == 24)); then
            warn "accepting snapshot after source files vanished during transfer"
            return 0
        fi
        return "$rc"
    }
    [[ ! -s $err ]] || cat -- "$err" >&2
}

# Copies everything into staging: one rsync of /home and /etc (possibly from a
# remote host), or one pass per tree with ZFS. Hardlink mode links unchanged
# files to the newest backup.
copy_to_staging() {
    local err=$1 previous='' remote_host='' pattern i j path child
    local -a common_args exclude_args=() args

    # --modify-window=-1 compares timestamps to the nanosecond. By default rsync
    # compares whole seconds and skips a file rewritten at the same size within
    # the same second as the previous copy, leaving the old version in the backup.
    common_args=(-aHv --numeric-ids --delete-delay --partial-dir=.rsync-partial \
        --modify-window=-1 --rsync-path='sudo rsync')
    for pattern in "${EXCLUDES[@]}"; do
        exclude_args+=(--exclude="$pattern")
    done
    # Staging starts out with old files, so excluded paths must be deleted there.
    ((${#EXCLUDES[@]} == 0)) || exclude_args+=(--delete-excluded)
    on_btrfs || previous=$(newest_backup || :)

    if ((${#TREE_PATHS[@]} == 0)); then
        args=("${common_args[@]}" "${exclude_args[@]}")
        if [[ $HOST != "$LOCAL_HOST" ]]; then
            [[ ${SUDO_USER:-} ]] || die "SUDO_USER is required for remote backup of $HOST"
            args+=(-e "ssh -o BatchMode=yes -o ConnectTimeout=30")
            remote_host="${SUDO_USER}@${HOST}:"
        fi
        [[ $previous ]] && args+=(--link-dest="$previous")
        rsync_pass "$err" "${args[@]}" "${remote_host}/home" "${remote_host}/etc" "$STAGING/"
        return
    fi

    # One pass per tree. Trees mounted below this one are copied by their own
    # pass, so here their mount points are neither copied (H) nor deleted (P).
    for i in "${!TREE_PATHS[@]}"; do
        path=${TREE_PATHS[i]}
        args=("${common_args[@]}")
        for j in "${!TREE_PATHS[@]}"; do
            [[ ${TREE_PATHS[j]} == "$path"/* ]] || continue
            child=${TREE_PATHS[j]#"$path"/}
            args+=(--filter="H /$child/" --filter="P /$child/")
        done
        args+=("${exclude_args[@]}")
        [[ $previous ]] && args+=(--link-dest="$previous$path")
        rsync_pass "$err" "${args[@]}" "${TREE_SOURCES[i]}" "$STAGING$path/" || return
    done
}

# Copies into staging until it succeeds with the free-space reserve intact. When
# the drive is full, make_room deletes one backup and the copy is tried again;
# any other rsync failure ends the run, keeping staging for the next one.
copy_making_room() {
    local rc

    while true; do
        verify_backup_mount
        if copy_to_staging "$RSYNC_ERR"; then
            verify_backup_mount
            enough_free_space && return 0
            echo "Destination is below free-space reserve after rsync; cleaning up and retrying"
            make_room
            continue
        else
            rc=$?
        fi
        verify_backup_mount
        if ! out_of_space_failure "$RSYNC_ERR" "$rc"; then
            echo "Error: rsync failed with rc=$rc and destination does not look space-constrained"
            if on_btrfs; then
                echo "Keeping staging subvolume as it is; not taking a snapshot"
            else
                echo "Keeping staging directory as incomplete; not rotating snapshot"
            fi
            exit "$rc"
        fi
        echo "rsync failed due to likely destination space/inode exhaustion; cleaning up and retrying"
        make_room
    done
}

# Turns staging into the new backup. The marker goes in before the snapshot is
# taken, so every backup carries it; a btrfs snapshot is committed to disk by the
# time the command returns.
publish_backup() {
    printf 'snapshot_epoch=%s\ncompleted_at=%s\nsource_host=%s\n' \
        "$NEW_EPOCH" "$(TZ=UTC0 printf '%(%FT%TZ)T' "$NEW_EPOCH")" "$HOST" \
        >"$STAGING/$COMPLETE_MARKER"
    [[ ! -e $NEW_BACKUP && ! -L $NEW_BACKUP ]] || die "snapshot already exists: $NEW_BACKUP"
    if on_btrfs; then
        btrfs subvolume snapshot -r "$STAGING" "$NEW_BACKUP"
        remove_staging_marker
    else
        mv -T -- "$STAGING" "$NEW_BACKUP"
    fi
    backup_epoch "$NEW_BACKUP" || die "the new backup is missing or incomplete: $NEW_BACKUP"
    on_btrfs && { is_subvolume "$NEW_BACKUP" || die "the new backup is not a btrfs snapshot: $NEW_BACKUP"; }
    return 0
}

# --- The run.

for command in cat chmod date df find findmnt flock grep install mkdir mktemp mv nice readlink rm rsync stat tee; do
    command -v "$command" >/dev/null || die "$command is required"
done

# Logs and lock. The lock is per host, so backups of different hosts can run at
# the same time; the log of the previous run is kept as .old.
prepare_root_dir "$LOG_DIR" 0755
prepare_root_dir "$LOCK_DIR" 0700
LOG_FILE=${LOG_DIR}/${SCRIPT_NAME}.${HOST}.log
OLD_LOG_FILE=${LOG_FILE}.old
[[ ! -e $LOG_FILE || -f $LOG_FILE && ! -L $LOG_FILE ]] ||
    die "log path must be a regular file: $LOG_FILE"
[[ ! -e $OLD_LOG_FILE || -f $OLD_LOG_FILE && ! -L $OLD_LOG_FILE ]] ||
    die "old log path must be a regular file: $OLD_LOG_FILE"

exec 9>"${LOCK_DIR}/${SCRIPT_NAME}.${HOST}.lock"
flock -n 9 || die "another backup for $HOST is in progress"

[[ ! -e $LOG_FILE ]] || mv -f -- "$LOG_FILE" "$OLD_LOG_FILE"
# Left behind by a run that was killed; the lock says none is in use.
for stale in "$LOG_DIR/$SCRIPT_NAME.$HOST.rsync."*; do
    rm -f -- "$stale" || :
done
exec &> >(tee -- "$LOG_FILE")

# Runs on every exit, success or not, without changing the exit status.
finish() {
    local rc=$? finished

    trap - EXIT
    set +e
    [[ ! $RSYNC_ERR ]] || rm -f -- "$RSYNC_ERR"
    destroy_zfs_snapshots
    finished=$(date +%s)
    [[ $finished =~ ^[0-9]+$ ]] || finished=$RUN_STARTED
    printf 'Backup finished: %s (status=%d)\n' "$(date -u +%FT%TZ)" "$rc"
    printf 'Total run time: %d seconds\n' "$((finished - RUN_STARTED))"
    exit "$rc"
}
trap finish EXIT
printf 'Backup started: %s\n' "$(TZ=UTC0 printf '%(%FT%TZ)T' "$RUN_STARTED")"

# 1. Checks: the host directory, the backup drive, the configuration.
BACKUP_ROOT=$(readlink -e -- "$BACKUP_ROOT") || die "BACKUP_ROOT doesn't exist"
HOST_DIR=${BACKUP_ROOT}/${HOST}
[[ -d $HOST_DIR && ! -L $HOST_DIR ]] || die "host directory is missing or unsafe: $HOST_DIR"
root_controlled "$HOST_DIR" || die "host directory must be root-owned and not group/world writable: $HOST_DIR"
verify_backup_mount
select_mode
CONFIG_FILE=${HOST_DIR}/.config
if [[ -e $CONFIG_FILE || -L $CONFIG_FILE ]]; then
    [[ -f $CONFIG_FILE && ! -L $CONFIG_FILE ]] || die "config must be a regular file: $CONFIG_FILE"
    root_controlled "$CONFIG_FILE" || die "config must be root-owned and not group/world writable: $CONFIG_FILE"
    . "$CONFIG_FILE"
fi
validate_config

# 2. Tidy up after earlier runs, then list the backups.
mark_legacy_backups_complete
finish_interrupted_deletions
scan_backups

# 3. The new backup: its time, its label, and what it copies from where.
NEW_EPOCH=$(date -u +%s)
[[ $NEW_EPOCH =~ ^[0-9]+$ ]] || die "unexpected output from date: $NEW_EPOCH"
ZFS_SNAPSHOT_NAME=${ZFS_SNAPSHOT_PREFIX}-$NEW_EPOCH
plan_trees
((${#ZFS_DATASETS[@]} == 0)) || command -v zfs >/dev/null ||
    die "zfs is required to back up from ZFS snapshots"
choose_label
NEW_BACKUP=${HOST_DIR}/$(TZ=UTC0 printf '%(%F_%T)T' "$NEW_EPOCH")_${NEW_LABEL}
[[ ! -e $NEW_BACKUP && ! -L $NEW_BACKUP ]] || die "snapshot already exists: $NEW_BACKUP"
check_clock_and_retention

# 4. Freeze the sources and check they aren't emptied.
verify_backup_mount
if ((${#ZFS_DATASETS[@]})); then
    destroy_stale_zfs_snapshots
    create_zfs_snapshots
fi
check_sources_not_emptied

# 5. Copy.
if on_btrfs; then
    prepare_btrfs_staging
else
    choose_recycled_backup
    prepare_hardlink_staging "$RECYCLE"
    scan_backups # a recycled backup is staging now
fi
RSYNC_ERR=$(mktemp "${LOG_DIR}/${SCRIPT_NAME}.${HOST}.rsync.XXXXXX")
copy_making_room
# Everything is in staging now, so the ZFS snapshot is no longer needed.
destroy_zfs_snapshots

# 6. Publish and apply retention.
publish_backup
rm -f -- "$HOST_DIR/$ACCEPT_EMPTY_FILE"
prune_old_backups
