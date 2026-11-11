#!/usr/bin/env bash
# Build the async Canonical ABI fixture from its component text. Needs wasm-tools.
# Committed at test/fixtures/component/asyncabi.component.wasm; the suite is
# test/wasm_component_async_abi_SUITE.erl.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="$here/test/fixtures/component"
wasm-tools parse "$dir/asyncabi/asyncabi.wat" -o "$dir/asyncabi.component.wasm"
wasm-tools validate --features all "$dir/asyncabi.component.wasm"
