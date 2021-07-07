#!/bin/bash

password_length=${1:-16}
special_symbols="~,./@#%&?=+_-"

while true; do
    echo {a..z} {A..Z} {0..9} \
        | grep -oP "\S" \
        | sort -R \
        | head -n$((password_length - 1)) \
        | ( cat && echo ${special_symbols:$((RANDOM % ${#special_symbols})):1} ) \
        | sort -R \
        | tr -d '\n'
    echo
done \
    | sed '/[a-z]/!d; /[A-Z]/!d; /[0-9]/!d' \
    | head -n20
