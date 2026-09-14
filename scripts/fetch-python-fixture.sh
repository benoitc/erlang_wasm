#!/usr/bin/env bash
# Fetch a CPython build for the worker conformance suite.
#
# Shaped on `fetch-qjs-fixture.sh`, and for the same reason: this is somebody
# else's interpreter, 20 MB of it, fetched rather than committed the way the
# specification suite is cloned rather than vendored.
#
# **This one proves the path and is not the dependency.** The repository it
# comes from is heading for archival and its newest Python artifact is from
# 2023. The real one is a `wasm32-wasip1` build against the same pinned WASI
# SDK as the quickjs-ng reactor, which is also what Phase 6 snapshots need,
# since a command-shaped artifact can never support them.
#
# `wasm_worker_lang_SUITE` skips with this command when the file is absent;
# CI verifies the checksums first so that a skip cannot read as a pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/fixtures/lang"
URL="https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python%2F3.12.0%2B20231211-040d5a6/python-3.12.0.wasm"

mkdir -p "$DEST"
if [ -f "$DEST/python.wasm" ]; then
    echo "already present: $DEST/python.wasm"
    exit 0
fi
echo "fetching $URL"
curl -fsSL -o "$DEST/python.wasm.part" "$URL"
mv "$DEST/python.wasm.part" "$DEST/python.wasm"
echo "fetched $(wc -c < "$DEST/python.wasm") bytes to $DEST/python.wasm"
