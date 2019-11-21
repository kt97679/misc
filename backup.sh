#!/bin/bash

set -ue

HOST=${1:-}
BACKUP_NUM=999
WORK_DIR=$(cd $(dirname $0) && pwd)

rsync_options=""
remote_host=""
if [ -z "$HOST" ] ; then
    HOST=$(hostname -s)
else
    rsync_options="-e ssh"
    remote_host="${LOGNAME}@${HOST}:"
fi

[ -d ${WORK_DIR}/${HOST} ] || {
    echo "Error: directory ${WORK_DIR}/${HOST} doesn't exist"
    exit
}
[ -f ${WORK_DIR}/${HOST}/.config ] && . ${WORK_DIR}/${HOST}/.config
current=${WORK_DIR}/${HOST}/$(date +%F_%T)/
previous=$(ls -dt ${WORK_DIR}/${HOST}/* | head -n1)
ls -dt ${WORK_DIR}/${HOST}/* | tail -n +${BACKUP_NUM} | xargs rm -rf
[ -n "$previous" ] && rsync_options+=" --link-dest=$previous"

sudo -E rsync -av --ignore-errors --rsync-path='sudo rsync' $rsync_options ${remote_host}{/home,/etc} $current

# ls -dt /media/kvt/backup/*/*|grep -v -f <(for x in /media/kvt/backup/*; do [ -d $x ] && ls -dt $x/*|head -n5; done)|tail -n 1
#while [ $(df --output=avail $WORK_DIR|tail -n 1) == 0 ]; do
#    oldest="$(ls -rdt ${WORK_DIR}/${BASE_NAME}-*|head -n1)"
#    sudo rm -rf "$oldest"
#done
