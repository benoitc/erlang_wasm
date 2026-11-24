#!/usr/bin/env bash
# Checks the NIF build's stamp on a copy of the build in a scratch directory,
# so the project's own `priv/' is never touched. Exits non-zero on the first
# check that fails.
#
#   scripts/test-build-nif.sh
#
# `erl' and `cc' are wrapped by scripts first on the path that log each call,
# which is how "nothing was started" is checked rather than assumed.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wasm_nif_stamp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tree/scripts" "$WORK/tree/c_src" "$WORK/bin" "$WORK/bin2"
cp "$ROOT/scripts/build-nif.sh" "$WORK/tree/scripts/"
cp "$ROOT/c_src/wasi_file_nif.c" "$WORK/tree/c_src/"
BUILD="$WORK/tree/scripts/build-nif.sh"
SO="$WORK/tree/priv/wasi_file_nif.so"
STAMP="$WORK/tree/priv/wasi_file_nif.stamp"
CALLS="$WORK/calls"

wrap() { # dir name real
    printf '#!/bin/sh\necho "%s" >> "%s"\nexec "%s" "$@"\n' "$2" "$CALLS" "$3" > "$1/$2"
    chmod +x "$1/$2"
}
wrap "$WORK/bin" erl "$(command -v erl)"
wrap "$WORK/bin" cc "$(command -v cc)"
PATH="$WORK/bin:$PATH"; export PATH
unset WASM_NIF_CFLAGS WASM_NIF_SANITIZE CC || true

fail() { echo "FAIL: $*"; exit 1; }
build() { : > "$CALLS"; "$BUILD" > "$WORK/out" 2>&1; }
built() { grep -q "wasm: built" "$WORK/out"; }
started() { grep -c "^$1\$" "$CALLS" || true; }
consistent() { [ "$(tail -1 "$STAMP")" = "so $(cksum < "$SO")" ]; }

# A first build builds and stamps.
build; built || fail "first build did not build"; consistent || fail "stamp does not name the library"

# The same build again starts neither erl nor the compiler.
build; built && fail "an unchanged build rebuilt"
[ "$(started erl)" = 0 ] || fail "an unchanged build started erl"
[ "$(started cc)" = 0 ] || fail "an unchanged build started the compiler"
echo "ok: an unchanged build starts neither erl nor the compiler"

# A different flag rebuilds.
WASM_NIF_CFLAGS=-DWASM_NIF_STAMP_TEST build; built || fail "a new flag did not rebuild"
echo "ok: a changed flag rebuilds"

# A different erl first on the path rebuilds.
build; built || fail "dropping the flag did not rebuild"
wrap "$WORK/bin2" erl "$(command -v erl)"
PATH="$WORK/bin2:$PATH" build; built || fail "a different erl did not rebuild"
echo "ok: a different erl rebuilds"

# A changed source rebuilds.
echo "/* stamp test */" >> "$WORK/tree/c_src/wasi_file_nif.c"
build; built || fail "a changed source did not rebuild"
echo "ok: a changed source rebuilds"

# A library replaced behind the stamp's back rebuilds.
build; built && fail "an unchanged build rebuilt"
printf 'x' >> "$SO"
build; built || fail "a changed library did not rebuild"
echo "ok: a library that is not the stamped one rebuilds"

# Two builds at once with different flags, then a third with the first's: it
# finds a library and stamp that agree, or it rebuilds; either way it ends
# with a pair that agrees.
for i in 1 2 3; do
    ( WASM_NIF_CFLAGS=-DA "$BUILD" > /dev/null 2>&1 ) &
    ( WASM_NIF_CFLAGS=-DB "$BUILD" > /dev/null 2>&1 ) &
    wait
    WASM_NIF_CFLAGS=-DA build
    consistent || fail "after concurrent builds the stamp names another library"
    grep -q "^flags cc||-DA|" "$STAMP" || fail "after concurrent builds the stamp has the other build's flags"
done
echo "ok: concurrent builds leave a library and stamp that agree"
