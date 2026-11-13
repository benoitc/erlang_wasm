#!/bin/sh
# Fetch the two upstream test suites at the commits this project is tested
# against. Used by CI and by `make suites`, so both run the same tests.
#
# Neither suite is vendored, and both used to be cloned from a moving branch:
# the same commit of this project could pass on one run and fail the next, and
# "conformance passed" meant whatever upstream held that day. To move a pin,
# change its commit here, run the suites, and commit the change.
#
#   scripts/fetch-suites.sh [DIR]     # DIR defaults to the current directory
set -eu

DIR=${1:-.}

fetch() {
    name=$1 url=$2 commit=$3
    dest="$DIR/$name"
    if [ -d "$dest" ]; then
        return 0
    fi
    git init -q "$dest"
    git -C "$dest" fetch -q --depth 1 "$url" "$commit"
    git -C "$dest" checkout -q FETCH_HEAD
}

fetch testsuite https://github.com/WebAssembly/testsuite.git \
    92a3d806c7d70f5b63f125e6155b8d76304509f1
fetch wasi-testsuite https://github.com/WebAssembly/wasi-testsuite.git \
    9d84631e427729802085c3d172d0a63cd360a1fa
