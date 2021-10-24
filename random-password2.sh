#!/bin/bash

password_length=${1:-16}
punct_symbols="~,./@#%&?=+_-"
digit_symbols=$(printf "%s" {0..9})
upper_symbols=$(printf "%s" {A..Z})
lower_symbols=$(printf "%s" {a..z})
all_symbols=$punct_symbols$digit_symbols$upper_symbols$lower_symbols

generate_password() {
    local x i
    {
        for x in $punct_symbols $digit_symbols $upper_symbols $lower_symbols; do
            echo ${x:$((RANDOM % ${#x})):1}
        done
        for ((i = 3; i < password_length; i++)); do
            echo ${all_symbols:$((RANDOM % ${#all_symbols})):1}
        done
    } | sort -R | tr -d '\n'
    echo
}

for ((i = 0; i < 20; i++)); do
    generate_password
done
