#!/usr/bin/env bash
# Build the Phase 0 component-model fixture: a no-import component exporting
#   run: func(input: list<u8>) -> result<list<u8>, string>
# It is the decode/round-trip target for the component front-end and wasm_canon.
#
# Target wasm32-unknown-unknown, NOT wasm32-wasip1: a wasip1 Rust guest imports
# wasi_snapshot_preview1 (environ/fd_write/proc_exit), which would need a p1->p2
# adapter and WASI host support. unknown-unknown imports nothing, so the component
# exercises decode + Canonical ABI + instantiate + call with no WASI 0.2 host.
#
# Needs: rustup target wasm32-unknown-unknown, wasm-tools. Output committed at
# test/fixtures/component/echo.component.wasm.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="$here/test/fixtures/component/echo"
out="$here/test/fixtures/component/echo.component.wasm"

rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
( cd "$src" && cargo build --release --target wasm32-unknown-unknown )
core="$src/target/wasm32-unknown-unknown/release/echo.wasm"

[ "$(wasm-tools print "$core" | grep -c '(import')" = "0" ] || {
  echo "fixture core module has imports; expected none" >&2; exit 1; }

wasm-tools component new "$core" -o "$out"
wasm-tools validate --features component-model "$out"
echo "built $out"
wasm-tools component wit "$out"
