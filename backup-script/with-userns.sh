#!/bin/bash
#
# Runs a command (by default the test suite) with Ubuntu's restriction on
# unprivileged user namespaces lifted, and puts it back afterwards: also after a
# failure or Ctrl-C. Lifting it takes sudo; the command itself runs as you. As
# root, or with the restriction already off, it simply runs the command.
#
# usage: tests/with-userns.sh [COMMAND...]        default: bash tests/run.sh

set -uo pipefail

SETTING=kernel.apparmor_restrict_unprivileged_userns
FILE=${USERNS_SETTING_FILE:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}

(($#)) || set -- bash "$(dirname -- "$0")/run.sh"

# Root needs no user namespaces, and a kernel without the setting has no restriction.
if ((EUID == 0)) || [[ ! -r $FILE ]]; then
    exec "$@"
fi

# Runs at the same time would put the restriction back under each other's feet.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/with-userns.lock" || exit 1
flock -w 600 9 || { echo "Error: another run has held the lock for 10 minutes" >&2; exit 1; }

if [[ $(<"$FILE") != 1 ]]; then
    "$@"
    exit
fi

restore() {
    if sudo sysctl -q "$SETTING=1" && [[ $(<"$FILE") == 1 ]]; then
        echo "Restriction on user namespaces back on"
    else
        echo "Warning: could not turn the restriction back on; run: sudo sysctl $SETTING=1" >&2
    fi
}
echo "Lifting the restriction on user namespaces for the test run (sudo)"
sudo sysctl -q "$SETTING=0" || { echo "Error: could not lift it" >&2; exit 1; }
trap restore EXIT
trap 'exit 130' INT TERM HUP

"$@"
