#!/usr/bin/env bash
# Print the command CPython's Makefile would run to link python.wasm.
#
#   scripts/python-link-line.sh cpython/cross-build/wasm32-wasip1
#
# `make -n python.wasm` alone is not enough: once python.wasm exists and is
# up to date, make prints "python.wasm is up to date" instead of a recipe.
# `-W Programs/python.o` tells make to treat that object as newer than any
# target that depends on it, so the link recipe is printed every time. The
# line is then checked, because handing whatever make said to a shell is how
# build-python-reactor.sh used to fail.
#
# This lives in its own file so wasm_scripts_SUITE can run it against a
# Makefile of its own, without a CPython tree.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 BUILD_DIR" >&2; exit 2; }
B="$1"

OUT="$(cd "$B" && make -n -W Programs/python.o python.wasm)" || {
    echo "make -n python.wasm failed in $B:" >&2
    printf '%s\n' "$OUT" >&2
    exit 1
}
LINK="$(printf '%s\n' "$OUT" | grep -- '-o python.wasm' || true)"
case "$(printf '%s\n' "$LINK" | grep -c .)" in
    1) printf '%s\n' "$LINK" ;;
    0) echo "no link line for python.wasm in $B; make said:" >&2
       printf '%s\n' "$OUT" >&2
       exit 1 ;;
    *) echo "more than one link line for python.wasm in $B:" >&2
       printf '%s\n' "$LINK" >&2
       exit 1 ;;
esac
