#!/bin/bash

set -eu

print_arg() {
    local j=$((i+1))
    echo "$j: $1"
    i=$j
}

i=0
while (( $# )); do
    print_arg "$1"
    shift
done
