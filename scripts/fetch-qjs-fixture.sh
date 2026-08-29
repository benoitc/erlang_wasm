#!/usr/bin/env bash
# Fetch a real QuickJS build for test/wasm_lang_SUITE.
#
# This is somebody else's program, compiled by somebody else's toolchain,
# which is the point: it is the only module here that was not written for this
# runtime. It is 1.8 MB, so it is fetched rather than committed, the same way
# the specification suite is cloned rather than vendored.
#
# wasm_lang_SUITE skips with this command when the file is absent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/fixtures/lang"
URL="https://github.com/second-state/wasmedge-quickjs/releases/download/v0.5.0-alpha/wasmedge_quickjs.wasm"

mkdir -p "$DEST"
if [ -f "$DEST/qjs.wasm" ]; then
    echo "already present: $DEST/qjs.wasm"
    exit 0
fi
echo "fetching $URL"
curl -fsSL -o "$DEST/qjs.wasm.part" "$URL"
mv "$DEST/qjs.wasm.part" "$DEST/qjs.wasm"
echo "fetched $(wc -c < "$DEST/qjs.wasm") bytes to $DEST/qjs.wasm"
