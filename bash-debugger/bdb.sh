#!/bin/bash
# shellcheck disable=SC2162,SC1090

_e() { echo $'\e['"${1:-}"m ; }

__dbg__breakpoints=()
__dbg__trace=2
__dbg__trap() {
    local __dbg__cmd __dbg__cmd_args __dbg__set="$(set +o)" \
        __dbg__do_break=false
    set +eu
    ((__dbg__trace == 1)) \
        && echo "$(_e 36)${BASH_SOURCE[1]}:$(_e 32)${BASH_LINENO[0]}:$(_e) $BASH_COMMAND"
    for __dbg__breakpoint in "${__dbg__breakpoints[@]}"; do
        eval "$__dbg__breakpoint" && __dbg__do_break=true && break
    done

    ((__dbg__trace == 2)) || $__dbg__do_break && {
        ((__dbg__trace == 0)) \
            && echo -n "$(_e 36)$(basename "${BASH_SOURCE[1]}"):" \
            && echo "$(_e 32)${BASH_LINENO[0]}: $(_e) $BASH_COMMAND"

        ((__dbg__trace == 2)) && __dbg__trace=0
        while read -p "$(_e 34)bdb> $(_e)"  __dbg__cmd __dbg__cmd_args; do
            case $__dbg__cmd in
                '') eval "$__dbg__set" && return 0 ;;
                trace) ((__dbg__trace ^= 1)) ;;
                bl) printf "%s\n" "${__dbg__breakpoints[@]}" \
                    | grep . | cat -n ;;
                ba) __dbg__breakpoints+=("$__dbg__cmd_args") ;;
                bd) unset __dbg__breakpoints[$((__dbg__cmd_args - 1))] \
                    && __dbg__breakpoints=("${__dbg__breakpoints[@]}") ;;
                *) eval "$__dbg__cmd $__dbg__cmd_args" ;;
            esac
        done
    }
}

set -T
trap "__dbg__trap >/dev/tty" debug

. "$@"
