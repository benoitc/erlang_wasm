#!/usr/bin/env bash
# Build the hand-written component fixtures listed below from their component
# text: test/fixtures/component/<dir>/<name>.wat becomes
# test/fixtures/component/<name>.component.wasm, committed beside the others.
# The other directories there with .wat files are built by their own suites.
# It also converts wasmtime's test scripts for the component threading
# built-ins into test/fixtures/component/wast-threading/: one JSON command list
# per script and a binary per component, read by wasm_component_wast_SUITE.
# They come from the wasmtime checkout scripts/build-wasmtime-p2.sh makes, at
# the tag it pins.
# Needs wasm-tools.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="$here/test/fixtures/component"
for src in asyncabi/asyncabi wasi3keys/wasi3keys wasi3keys/asyncping \
           asynctasks/asynctasks composedasync/composedasync \
           ifaceexports/ifaceexports; do
  out="$dir/$(basename "$src").component.wasm"
  wasm-tools parse "$dir/$src.wat" -o "$out"
  wasm-tools validate --features all "$out"
done

tag="$(sed -n 's/^tag="\(.*\)"$/\1/p' "$here/scripts/build-wasmtime-p2.sh")"
wasmtime="${WASMTIME_P2_SRC:-$here/.wasmtime-src}/wasmtime"
test "$(git -C "$wasmtime" describe --tags)" = "$tag"
scripts="$wasmtime/tests/misc_testsuite/component-model-threading"
wast="$dir/wast-threading"
rm -rf "$wast"
mkdir -p "$wast"
for src in "$scripts"/*.wast; do
  name="$(basename "$src" .wast)"
  wasm-tools json-from-wast "$src" -o "$wast/$name.json" --wasm-dir "$wast"
  # The source path is the builder's; keep only the script's name.
  sed -i.bak "s|\"source_filename\": \"[^\"]*\"|\"source_filename\": \"$name.wast\"|" \
    "$wast/$name.json"
  rm "$wast/$name.json.bak"
done
