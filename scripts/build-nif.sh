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
# has to be loaded into the process first. See the sanitizer section of
# `docs/wasi.md` for the two ways to arrange that.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/c_src/wasi_file_nif.c"
PRIV="$ROOT/priv"
OUT="$PRIV/wasi_file_nif.so"

command -v erl >/dev/null || { echo "wasm: no erl; skipping NIF"; exit 0; }
INC="$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')"
INC="$(ls -d "$INC"/erts-*/include 2>/dev/null | head -1)"
[ -n "$INC" ] || { echo "wasm: no erts include dir; skipping NIF"; exit 0; }

CC="${CC:-cc}"
command -v "$CC" >/dev/null || { echo "wasm: no C compiler; skipping NIF (pure Erlang fallback in use)"; exit 0; }

SAN=""
if [ -n "${WASM_NIF_SANITIZE:-}" ]; then
    SAN="-fsanitize=${WASM_NIF_SANITIZE} -fno-omit-frame-pointer -g -O1"
    echo "wasm: NIF instrumented with ${WASM_NIF_SANITIZE}"
fi

mkdir -p "$PRIV"
case "$(uname -s)" in
    Darwin) LDFLAGS="-dynamiclib -undefined dynamic_lookup" ;;
    *)      LDFLAGS="-shared" ;;
esac

if "$CC" -O2 -fPIC $SAN $LDFLAGS -I"$INC" -o "$OUT" "$SRC" 2>/tmp/wasm_nif_build.log; then
    echo "wasm: built $OUT"
else
    echo "wasm: NIF build failed, using pure Erlang fallback:"
    sed 's/^/  /' /tmp/wasm_nif_build.log | head -5
fi
exit 0
