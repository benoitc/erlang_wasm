#!/usr/bin/env bash
# Rebuild test/fixtures/native/real.wasm from real.c.
#
# Uses a clang that can target wasm32. Dev-time only, and the built artefact is
# committed so the test runs without a wasm toolchain present.
#
# Note: this is freestanding (-nostdlib), not WASI. A WASI binary needs a
# sysroot (wasi-sdk, or rustup's wasm32-wasip1 std), neither of which MacPorts
# rust or Apple clang provide.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CC:-}"
if [ -z "$CC" ]; then
    for c in clang-mp-22 clang-mp-21 clang-mp-20 clang; do
        if command -v "$c" >/dev/null && "$c" --print-targets 2>/dev/null | grep -q wasm32; then
            CC="$c"; break
        fi
    done
fi
[ -n "$CC" ] || { echo "no clang able to target wasm32; set CC=" >&2; exit 1; }
"$CC" --target=wasm32 -O2 -nostdlib -Wl,--no-entry -Wl,--export-dynamic \
      -Wl,--allow-undefined \
      -o "$ROOT/test/fixtures/native/real.wasm" "$ROOT/test/fixtures/native/real.c"
echo "built with $CC"
