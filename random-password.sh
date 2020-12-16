#!/bin/bash

password_length=${1:-16}

tr -dc [:graph:] </dev/urandom \
    | fold -w $password_length \
    | sed '/[a-z]/!d; /[A-Z]/!d; /[0-9]/!d' \
    | grep "^[a-zA-Z0-9]*[~,./@#%&?=+_-][a-zA-Z0-9]*$" \
    | grep -v "\(.\).*\1" \
    | head -n20
