#!/usr/bin/env bash
# Build the hand-written component fixtures listed below from their component
# text: test/fixtures/component/<dir>/<name>.wat becomes
# test/fixtures/component/<name>.component.wasm, committed beside the others.
# The other directories there with .wat files are built by their own suites.
# Needs wasm-tools.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="$here/test/fixtures/component"
for src in asyncabi/asyncabi wasi3keys/wasi3keys wasi3keys/asyncping \
           asynctasks/asynctasks; do
  out="$dir/$(basename "$src").component.wasm"
  wasm-tools parse "$dir/$src.wat" -o "$out"
  wasm-tools validate --features all "$out"
done
