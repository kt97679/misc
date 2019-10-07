#!/bin/bash

set -ue

[ -d .git ] || {
    echo "Error: this script should be run in the root directory of the git repository"
    exit
}

origin=$(git config --get remote.origin.url)

[ -z "$origin" ] && echo "Error: failed to retrieve remote.origin.url" && exit

read -p "This operation can't be reverted. Please hit enter to continue or ctrl-c to abort"

rm -rf .git
git init
git add .
git commit -m "Initial commit"
git remote add origin "$origin"
git push -u --force origin master
