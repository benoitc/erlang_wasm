#!/usr/bin/env bash
# Build test/fixtures/lang/lua_reactor.wasm: Lua 5.4 as an init()/handle()
# reactor, the third guest and the one that is deliberately unlike the other
# two. QuickJS and CPython hold 211 KB and 7.4 MB in an image; Lua holds about
# 77 KB, which is where a snapshot mechanism that assumed bulk would show it.
#
# Two flags carry all the difficulty, and both are about setjmp:
#
#   -mllvm -wasm-enable-sjlj        Lua signals errors with longjmp, and on
#                                   WebAssembly that needs exception handling.
#   -mllvm -wasm-use-legacy-eh=false
#                                   LLVM still emits the *superseded* encoding
#                                   by default. This runtime implements the
#                                   standardised one -- `try_table`, `throw`,
#                                   `throw_ref` -- so without this the module
#                                   fails to load with `illegal_opcode` on
#                                   opcode 6, which is the legacy `try`.
#
#   WASI_SDK=/path/to/wasi-sdk-34.0-arm64-macos scripts/build-lua-reactor.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/fixtures/lang"
SRC="$DEST/lua_reactor/worker_reactor.c"

VERSION="${LUA_VERSION:-5.4.9}"
SHA256="2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6"
WASI_SDK="${WASI_SDK:-$HOME/.local/opt/wasi-sdk-34.0-arm64-macos}"

[ -x "$WASI_SDK/bin/clang" ] || {
    echo "no WASI SDK at $WASI_SDK; set WASI_SDK, or install wasi-sdk-34" >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "fetching Lua $VERSION"
curl -fsSL -o "$WORK/lua.tar.gz" "https://www.lua.org/ftp/lua-$VERSION.tar.gz"
# The tarball **is** checksummed, unlike the artifacts this script produces: it
# is fetched rather than built, and lua.org publishes no signature.
if command -v shasum >/dev/null 2>&1; then
    echo "$SHA256  $WORK/lua.tar.gz" | shasum -a 256 -c - >/dev/null
else
    echo "$SHA256  $WORK/lua.tar.gz" | sha256sum -c - >/dev/null
fi
tar xzf "$WORK/lua.tar.gz" -C "$WORK"

# Everything but the two entry points: `lua.c` is the interpreter's `main` and
# `luac.c` is the compiler's.
cp -R "$WORK/lua-$VERSION/src" "$WORK/lib"
rm -f "$WORK/lib/lua.c" "$WORK/lib/luac.c"

echo "building"
"$WASI_SDK/bin/clang" --target=wasm32-wasip1 -mexec-model=reactor -O2 \
    -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false \
    -I "$WORK/lib" \
    -DLUA_TMPNAMBUFSIZE=32 '-Dlua_tmpnam(b,e)={((void)(b)); (e)=1;}' \
    -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
    -o "$DEST/lua_reactor.wasm" "$SRC" "$WORK"/lib/*.c \
    -lsetjmp -lwasi-emulated-signal -lwasi-emulated-process-clocks -lm

echo "built $(wc -c < "$DEST/lua_reactor.wasm") bytes to $DEST/lua_reactor.wasm"
