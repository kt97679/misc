#!/bin/bash
tr -dc [:graph:] </dev/urandom \
    | fold -w 16 \
    | grep "[a-z]" \
    | grep "[A-Z]" \
    | grep "[0-9]" \
    | grep "^[a-zA-Z0-9]*[,./@#%&?=+_-][a-zA-Z0-9]*$" \
    | grep -v "\(.\).*\1" \
    | head -n20
