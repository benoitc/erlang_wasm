#!/usr/bin/env bash
# Run a suite with the NIF under AddressSanitizer, in a Linux container.
#
#   ./scripts/sanitize.sh                      # the NIF suite
#   ./scripts/sanitize.sh test/wasi_SUITE      # any suite
#
# A container rather than the host because a sanitizer has to be in the process
# before anything it watches, and only Linux lets you arrange that without
# rebuilding the emulator: LD_PRELOAD survives the exec from `erl` to the
# emulator there, and on macOS it does not.
#
# ThreadSanitizer is not offered here. Preloading it segfaults the emulator,
# because unlike AddressSanitizer it needs the whole program instrumented. That
# means an emulator built with it, which is a much longer road; see the
# sanitizer section of `docs/wasi.md`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="${1:-test/wasi_nif_SUITE}"
IMAGE="${WASM_SANITIZE_IMAGE:-erlang:29}"

command -v docker >/dev/null || { echo "sanitize: docker not found"; exit 1; }

# Copied in rather than mounted: the build is a different architecture and a
# different object format from whatever is in the host's `_build`.
docker run --rm -v "$ROOT":/src:ro -w /w "$IMAGE" bash -lc '
  set -e
  mkdir -p /w && cp -a /src/. /w/ && cd /w
  rm -rf _build priv/*.so priv/*.dSYM
  # Kept for the test run as well: `rebar3 ct` recompiles, and without it
  # the NIF would be rebuilt uninstrumented.
  export WASM_NIF_SANITIZE=address
  rebar3 compile >/dev/null
  export LD_PRELOAD=$(gcc -print-file-name=libasan.so)
  # Leak detection is off: the emulator holds allocations for its whole life by
  # design, so it reports pages of them and none are the NIF. Use-after-return
  # detection is off by default, and a stack buffer used after its function
  # returned is a defect this NIF has had.
  export ASAN_OPTIONS=detect_stack_use_after_return=1:detect_leaks=0:abort_on_error=1
  rebar3 ct --suite='"$SUITE"'
'
