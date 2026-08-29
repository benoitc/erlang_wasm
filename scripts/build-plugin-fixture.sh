#!/usr/bin/env bash
# Rebuild test/fixtures/plugin/plugin.wasm from plugin.rs.
#
# Needs only the Rust wasm target, which brings its own sysroot:
#   rustup target add wasm32-wasip1
#
# Dev-time only. The artefact is committed so the tests run without a Rust
# toolchain, the same as the wasi_demo fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v rustc >/dev/null || { echo "rustc not found" >&2; exit 1; }
rustc --target wasm32-wasip1 -O --crate-type=cdylib \
      -o "$ROOT/test/fixtures/plugin/plugin.wasm" \
      "$ROOT/test/fixtures/plugin/plugin.rs"
# Two megabytes of debug information for a forty-kilobyte plugin, otherwise.
if command -v wasm-tools >/dev/null; then
    wasm-tools strip "$ROOT/test/fixtures/plugin/plugin.wasm" \
        -o "$ROOT/test/fixtures/plugin/plugin.wasm"
fi
echo "built $(wc -c < "$ROOT/test/fixtures/plugin/plugin.wasm") bytes"
