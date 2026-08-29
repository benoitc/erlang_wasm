#!/usr/bin/env bash
# Rebuild test/fixtures/rust/wasi_demo.wasm from main.rs.
#
# Requires the Rust wasm32-wasip1 target:
#   rustup target add wasm32-wasip1
#
# Dev-time only. The stripped artefact is committed so the acceptance test runs
# without a Rust toolchain present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v rustc >/dev/null || { echo "rustc not found" >&2; exit 1; }
rustc --target wasm32-wasip1 -O \
      -o /tmp/wasi_demo_full.wasm "$ROOT/test/fixtures/rust/main.rs"
if command -v wasm-tools >/dev/null; then
    wasm-tools strip /tmp/wasi_demo_full.wasm \
        -o "$ROOT/test/fixtures/rust/wasi_demo.wasm"
else
    cp /tmp/wasi_demo_full.wasm "$ROOT/test/fixtures/rust/wasi_demo.wasm"
fi
echo "built $(wc -c < "$ROOT/test/fixtures/rust/wasi_demo.wasm") bytes"
