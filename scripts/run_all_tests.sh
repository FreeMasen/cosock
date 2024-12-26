#! /bin/bash

set -e

REPO_ROOT="$(dirname $(dirname "$(realpath "${BASH_SOURCE:-$0}")"))"

for f in $REPO_ROOT/test/**/*.lua
do
    printf "%s\n" "$(basename $f)"
    ./lua $f
done
