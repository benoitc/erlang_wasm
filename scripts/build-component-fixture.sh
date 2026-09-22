#!/usr/bin/env bash
# Build the component-model fixtures: no-import components that exercise the
# component front-end and wasm_canon (the Canonical ABI) without any WASI host.
#   echo    -- run: func(list<u8>) -> result<list<u8>, string>
#   vectors -- one echo function per WIT value type (the ABI test vectors)
#
# Target wasm32-unknown-unknown, NOT wasm32-wasip1: a wasip1 Rust guest imports
# wasi_snapshot_preview1, which would need a p1->p2 adapter and WASI host support.
# unknown-unknown imports nothing. Needs rustup's wasm32-unknown-unknown and
# wasm-tools. Committed at test/fixtures/component/<name>.component.wasm.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true

for name in echo vectors counter; do
  src="$here/test/fixtures/component/$name"
  out="$here/test/fixtures/component/$name.component.wasm"
  ( cd "$src" && cargo build --release --target wasm32-unknown-unknown )
  core="$src/target/wasm32-unknown-unknown/release/$name.wasm"
  [ "$(wasm-tools print "$core" | grep -c '(import')" = "0" ] || {
    echo "$name core module has imports; expected none" >&2; exit 1; }
  wasm-tools component new "$core" -o "$out"
  wasm-tools validate --features component-model "$out"
  echo "built $out"
done
