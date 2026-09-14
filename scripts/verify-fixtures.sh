#!/usr/bin/env bash
# Verify the language fixtures against their recorded checksums.
#
# Run in CI *before* the integration suite, because a missing or mismatched
# artifact has to fail the job rather than quietly reduce what ran. A suite
# that skips is green, and a green run that proved nothing is worse than a red
# one.
#
# `shasum -a 256 -c` on macOS, `sha256sum -c` on a minimal Linux container:
# this box happens to have both, and a stock install of either has only one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/test/fixtures/lang"

if command -v shasum >/dev/null 2>&1; then
    CHECK=(shasum -a 256 -c)
elif command -v sha256sum >/dev/null 2>&1; then
    CHECK=(sha256sum -c)
else
    echo "neither shasum nor sha256sum is available" >&2
    exit 1
fi

status=0
shopt -s nullglob
sums=("$DIR"/*.sha256)
if [ ${#sums[@]} -eq 0 ]; then
    echo "no checksum files in $DIR" >&2
    exit 1
fi

for sum in "${sums[@]}"; do
    artifact="${sum%.sha256}"
    name="$(basename "$artifact")"
    if [ ! -f "$artifact" ]; then
        echo "MISSING  $name (run scripts/fetch-${name%%.*}-fixture.sh)" >&2
        status=1
        continue
    fi
    if (cd "$DIR" && "${CHECK[@]}" "$(basename "$sum")" >/dev/null 2>&1); then
        echo "ok       $name"
    else
        echo "MISMATCH $name" >&2
        status=1
    fi
done
# Built artifacts are checked for presence and nothing else. A checksum would
# pin the machine that produced them rather than the recipe: the same pinned
# wasi-sdk 34 emits 1,351,069 bytes on arm64 macOS and 1,528,288 on x86-64
# Linux. Their integrity story is the pinned tag, the pinned SDK, and the build
# failing loudly. Presence still has to be checked, because a suite that skips
# is green and a green run that proved nothing is worse than a red one.
#
# Only the QuickJS reactor is required here, because it is the one the
# integration job builds and the one its groups need. The CPython reactor is
# built deliberately and its group skips with the command to build it, so
# demanding it would fail a job that was never going to run it.
for built in qjs_reactor.wasm:build-quickjs-reactor.sh \
             lua_reactor.wasm:build-lua-reactor.sh; do
    name="${built%%:*}"; how="${built##*:}"
    if [ -f "$DIR/$name" ]; then
        echo "present  $name (built, no checksum)"
    else
        echo "MISSING  $name (run scripts/$how)" >&2
        status=1
    fi
done

exit $status
