#!/usr/bin/env bash
# Build the optional WASI file NIF.
#
# Optional on purpose: it closes a time-of-check-to-time-of-use window in WASI
# path resolution, but the runtime works without it and falls back to the pure
# Erlang resolver. A missing C compiler must never fail the build, so this
# script reports and exits 0.
#
# Set WASM_NIF_SANITIZE to build it under a sanitizer:
#
#   WASM_NIF_SANITIZE=address rebar3 compile
#   WASM_NIF_SANITIZE=thread  rebar3 compile
#
# That instruments the NIF; it does not instrument the emulator, so the runtime
# has to be loaded into the process first. See "Run the NIF under a sanitizer"
# in `docs/contributing/nif.md` for the two ways to arrange that.
#
# A build that would produce the library already in place is skipped without
# starting `erl' or the compiler: `priv/wasi_file_nif.stamp' records what the
# last build used, and the library it produced.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/c_src/wasi_file_nif.c"
PRIV="$ROOT/priv"
OUT="$PRIV/wasi_file_nif.so"
STAMP="$PRIV/wasi_file_nif.stamp"

CC="${CC:-cc}"
# Extra compiler flags, such as -DWASM_NIF_STACK_CHECK for the check build.
EXTRA="${WASM_NIF_CFLAGS:-}"
OS="$(uname -s)"
SAN=""
if [ -n "${WASM_NIF_SANITIZE:-}" ]; then
    SAN="-fsanitize=${WASM_NIF_SANITIZE} -fno-omit-frame-pointer -g -O1"
fi

# A path with every symbolic link on it followed, without `readlink -f',
# which not every system has.
resolve() {
    p="$1"
    while [ -L "$p" ]; do
        l="$(readlink "$p")"
        case "$l" in /*) p="$l" ;; *) p="${p%/*}/$l" ;; esac
    done
    echo "$p"
}
# A file's identity: where it really is, its size and when it last changed.
# Few processes on purpose: this is what every unchanged build runs.
ident() { ls -lL "$(resolve "$1")"; }
sum() { cksum < "$1"; }

# Everything the library depends on, one line each. The header directory is
# the one the last build found by asking `erl', which is what lets an
# unchanged build skip starting `erl' at all: if `erl' itself or anything in
# that directory changed, a line differs and the build runs as before.
inputs() {
    echo "src $(sum "$SRC")"
    echo "script $(sum "$0")"
    echo "flags $CC|$SAN|$EXTRA|$OS"
    echo "erl $(ident "$(command -v erl)")"
    echo "cc $(ident "$(command -v "$CC")")"
    echo "inc $1 $(cat "$1"/*.h | cksum)"
}

# Up to date when the stamp's inputs are today's and the library on disk is
# the one built with them. The second half is what two builds at once cannot
# fool: each writes its stamp after its library, so a library paired with the
# other build's stamp has the wrong checksum and the next build rebuilds.
if [ -f "$STAMP" ] && [ -f "$OUT" ] && command -v erl >/dev/null \
        && command -v "$CC" >/dev/null; then
    OLD_INC="$(sed -n 's/^inc \([^ ]*\) .*/\1/p' "$STAMP")"
    if [ -n "$OLD_INC" ] && [ -d "$OLD_INC" ] \
            && [ "$(inputs "$OLD_INC"; echo "so $(sum "$OUT")")" \
                 = "$(cat "$STAMP")" ]; then
        exit 0
    fi
fi

command -v erl >/dev/null || { echo "wasm: no erl; skipping NIF"; exit 0; }
INC="$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')"
INC="$(ls -d "$INC"/erts-*/include 2>/dev/null | head -1)"
[ -n "$INC" ] || { echo "wasm: no erts include dir; skipping NIF"; exit 0; }

command -v "$CC" >/dev/null || { echo "wasm: no C compiler; skipping NIF (pure Erlang fallback in use)"; exit 0; }

if [ -n "$SAN" ]; then
    echo "wasm: NIF instrumented with ${WASM_NIF_SANITIZE}"
fi

mkdir -p "$PRIV"
case "$OS" in
    Darwin) LDFLAGS="-dynamiclib -undefined dynamic_lookup" ;;
    *)      LDFLAGS="-shared" ;;
esac

# Built under a name of its own, then renamed into place. A rename is atomic,
# so a runtime loading the NIF while another build runs sees the old file or
# the new one, never one half-written, and two builds at once cannot mix
# their output. Each build keeps its own log for the same reason. The stamp
# goes in after the library, by rename too, and names the library it was
# written for by its checksum.
TMP="$OUT.$$.tmp"
LOG="$(mktemp "${TMPDIR:-/tmp}/wasm_nif_build.XXXXXX")"
if "$CC" -O2 -fPIC $SAN $EXTRA $LDFLAGS -I"$INC" -o "$TMP" "$SRC" 2>"$LOG" \
        && mv -f "$TMP" "$OUT"; then
    echo "wasm: built $OUT"
    { inputs "$INC"; echo "so $(sum "$OUT")"; } > "$STAMP.$$.tmp" \
        && mv -f "$STAMP.$$.tmp" "$STAMP"
else
    echo "wasm: NIF build failed, using pure Erlang fallback:"
    sed 's/^/  /' "$LOG" | head -5
    rm -f "$STAMP"
fi
rm -f "$TMP" "$LOG" "$STAMP.$$.tmp"
exit 0
