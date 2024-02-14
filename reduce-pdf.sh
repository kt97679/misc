#!/bin/bash

set -eu

reduce_single_file() {
    local input_file=$1
    local temp_file=$(mktemp)
    local input_file_size=$(stat -c %s "$input_file")
    local temp_file_size=0

    trap "rm -f '$temp_file'" EXIT

    gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dBATCH -sOutputFile="$temp_file" "$input_file"
    temp_file_size=$(stat -c %s "$temp_file")
    ((temp_file_size < input_file_size)) && chmod 0644 "$temp_file" && mv "$temp_file" "$input_file"
    rm -f "$temp_file"
    trap - EXIT
}

for x in "$@"; do reduce_single_file "$x"; done
