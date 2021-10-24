#!/bin/bash

password_length=${1:-16}

punct_symbols="~,./@#%&?=+_-"
digit_symbols="0-9"
upper_symbols="A-Z"
lower_symbols="a-z"
all_symbols=$digit_symbols$upper_symbols$lower_symbols$punct_symbols

tr -dc $all_symbols </dev/urandom \
    | fold -w $password_length \
    | sed "/[$lower_symbols]/!d; /[$upper_symbols]/!d; /[$digit_symbols]/!d; /[$punct_symbols]/!d" \
    | head -n20

