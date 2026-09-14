#!/usr/bin/env bash
# Build test/fixtures/lang/qjs_reactor.wasm: quickjs-ng as an init()/handle()
# reactor, which is the shape initialized runtime snapshots need.
#
# The published qjs-wasi-reactor.wasm is not usable here. It exports qjs_init,
# qjs_get_context, qjs_destroy and the engine C API, and driving that needs a
# JSContext * returned by one call to be an argument to the next -- dataflow
# the worker kernel does not have, since `invoke` fixes every argument before
# execution begins. So the reactor is quickjs-ng's own library plus a shim of
# ours, test/fixtures/lang/qjs_reactor/worker_reactor.c, which keeps the
# context, the guest pointers, evaluation and result framing on its own side.
#
# The output is byte-identical on one host for a given tag, SDK and flag set,
# and NOT across hosts: the same wasi-sdk 34 emits 1,351,069 bytes on arm64
# macOS and 1,528,288 on x86-64 Linux. So there is no checksum beside it -- a
# hash would pin the machine rather than the recipe, and integrity here is the
# pinned tag, the pinned SDK and this script failing rather than guessing.
# Build it, do not commit it: 1.3 MB against a repository whose largest tracked
# file is 232 KB.
#
#   WASI_SDK=/path/to/wasi-sdk-34.0-arm64-macos scripts/build-quickjs-reactor.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/fixtures/lang"
SRC="$DEST/qjs_reactor/worker_reactor.c"

# Pinned, both of them. The same SDK builds the CPython reactor, so that two
# guests differing in behaviour differ for a reason other than their toolchain.
TAG="${QUICKJS_NG_TAG:-v0.16.2}"
WASI_SDK="${WASI_SDK:-$HOME/.local/opt/wasi-sdk-34.0-arm64-macos}"

[ -x "$WASI_SDK/bin/clang" ] || {
    echo "no WASI SDK at $WASI_SDK; set WASI_SDK, or install wasi-sdk-34" >&2
    echo "  https://github.com/WebAssembly/wasi-sdk/releases/tag/wasi-sdk-34" >&2
    exit 1
}
command -v cmake >/dev/null || { echo "cmake not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "cloning quickjs-ng $TAG"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" \
    https://github.com/quickjs-ng/quickjs.git "$WORK/quickjs-ng"

# The library and quickjs-libc through their own CMake rather than the
# published amalgam: the amalgam does not compile for WASI, because its libc
# half reaches for `environ` and `sighandler_t` behind guards that exclude
# wasi.
cmake -S "$WORK/quickjs-ng" -B "$WORK/build" -G "${CMAKE_GENERATOR:-Ninja}" \
      -DCMAKE_TOOLCHAIN_FILE="$WASI_SDK/share/cmake/wasi-sdk-p1.cmake" \
      -DWASI_SDK_PREFIX="$WASI_SDK" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF >/dev/null
cmake --build "$WORK/build" --target qjs qjs-libc >/dev/null

"$WASI_SDK/bin/clang" --target=wasm32-wasip1 -mexec-model=reactor -O2 \
    -I "$WORK/quickjs-ng" -D_GNU_SOURCE \
    -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
    -o "$DEST/qjs_reactor.wasm" "$SRC" \
    "$WORK/build/libqjs-libc.a" "$WORK/build/libqjs.a" \
    -lwasi-emulated-signal -lwasi-emulated-process-clocks -lm

echo "built $(wc -c < "$DEST/qjs_reactor.wasm") bytes to $DEST/qjs_reactor.wasm"
if command -v shasum >/dev/null 2>&1; then
    (cd "$DEST" && shasum -a 256 qjs_reactor.wasm)
else
    (cd "$DEST" && sha256sum qjs_reactor.wasm)
fi
