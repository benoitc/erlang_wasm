#!/bin/sh
# Fetch the two upstream test suites at the commits this project is tested
# against. Used by CI and by `make suites`, so both run the same tests.
#
# Neither suite is vendored, and both used to be cloned from a moving branch:
# the same commit of this project could pass on one run and fail the next, and
# "conformance passed" meant whatever upstream held that day. To move a pin,
# change its commit here, run this again, run the suites, and commit the
# change. An existing checkout is moved to the pin, or the script stops if
# you changed it: see `checkout-pin.sh'.
#
#   scripts/fetch-suites.sh [DIR]     # DIR defaults to the current directory
set -eu

DIR=${1:-.}
here=$(cd "$(dirname "$0")" && pwd)

fetch() {
    "$here/checkout-pin.sh" "$DIR/$1" "$2" "$3"
}

fetch testsuite https://github.com/WebAssembly/testsuite.git \
    92a3d806c7d70f5b63f125e6155b8d76304509f1
fetch wasi-testsuite https://github.com/WebAssembly/wasi-testsuite.git \
    9d84631e427729802085c3d172d0a63cd360a1fa
