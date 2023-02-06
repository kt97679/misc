#!/bin/bash

obj_001_001k="name"
obj_001_001v="entry 1"
obj_001_002k="url"
obj_001_002v="http://example.com"

obj_002_001k="name"
obj_002_001v="entry 2"

obj_003_001k="name"
obj_003_001v="entry 3"

main() {
    FN_PREFIX="impl_"
    OBJ_PREFIX="obj_"

    impl_exit() {
        [ "$1" = "help" ] && {
            echo "exit"
            echo "  will exit program"
            return
        }
        exit
    }

    impl_help() {
        [ "$1" = "help" ] && {
            echo "help"
            echo "  show help for all commands"
            return
        }
        local fn
        for fn in $(compgen -A function|grep "^${FN_PREFIX}"|sort); do
            $fn help
        done
    }

    impl_ls() {
        [ "$1" = "help" ] && {
            echo "ls"
            echo "  list entries"
            return
        }
        local name_key name_id
        while read name_key; do
            name_id=$(cut -f2 -d_ <<<$name_key)
            printf "%s: %s\n" "$name_id" "${!name_key}"
        done < <(set|grep "^${OBJ_PREFIX}[^=]*k=name$"|sed -e 's/k=.*/v/')
    }

    impl_cat() {
        [ "$1" = "help" ] && {
            echo "cat <entry_id>"
            echo "  show entry content"
            return
        }
        local entry_id=$1 key value
        while read key; do
            value=${key/k/v}
            printf "%s: %s\n" "${!key}" "${!value}"
        done < <(set|grep -oP "^${OBJ_PREFIX}${entry_id}_\d+k")
    }

    impl_rm() {
        [ "$1" = "help" ] && {
            echo "rm <entry_id>"
            echo "  delete entry"
            return
        }
        local entry_id=$1 var
        while read var; do
            unset $var
        done < <(set|grep -oP "^${OBJ_PREFIX}${entry_id}_[^=]+")
    }

    at_exit() {
        echo "at_exit"
    }

    trap at_exit EXIT

    local input
    while read -e -p "> " -a input; do
        [ "$(type -t "${FN_PREFIX}${input[0]}")" != "function" ] && {
            echo "Error: unknown command \"${input[0]}\""
            input=(help)
        }
        "${FN_PREFIX}${input[0]}" "${input[@]:1}"
    done
}

main "$@"
