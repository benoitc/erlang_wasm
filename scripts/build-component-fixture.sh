#!/usr/bin/env bash
# Build the component-model fixtures. Two kinds:
#   no-import  -- exercise the component front-end and wasm_canon (the Canonical
#                 ABI) with no host:
#     echo     -- run: func(list<u8>) -> result<list<u8>, string>
#     vectors  -- one echo function per WIT value type (the ABI test vectors)
#     counter  -- an exported resource (constructor, method, dtor)
#   import     -- the guest imports an interface the host supplies:
#     hostcall -- example:host/clock (flat args and results)
#     hostagg  -- example:agg/host   (a string both ways)
#     wasirandom -- wasi:random/random, the first real WASI 0.2 world
#     wasiclocks -- wasi:clocks monotonic-clock and wall-clock
#     wasienv    -- wasi:cli/environment
#     wasiio     -- wasi:cli/stdout + wasi:io/streams output-stream
#     wasiin     -- wasi:cli/stdin + wasi:io/streams input-stream
#     wasiiofull -- the fuller wasi:io: write path, skip, pollable/poll
#     wasifs     -- read-only wasi:filesystem (preopens + descriptor)
#     wasisock   -- wasi:sockets ip-name-lookup (network + resolve)
#     wasitcp    -- wasi:sockets tcp client + listener
#     wasiudp    -- wasi:sockets udp datagrams
#     wasiver    -- a versioned import id (@0.2.0), for version normalisation
#
# Target wasm32-unknown-unknown, NOT wasm32-wasip1: a wasip1 Rust guest imports
# wasi_snapshot_preview1, which would need a p1->p2 adapter. unknown-unknown
# imports only what its WIT world declares. Needs rustup's wasm32-unknown-unknown
# and wasm-tools. Committed at test/fixtures/component/<name>.component.wasm.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true

# Fixtures whose core module must import nothing (no host, no WASI world).
no_import=" echo vectors counter "

for name in echo vectors counter hostcall hostagg wasirandom wasiclocks wasienv wasiio wasiin wasiiofull wasifs wasisock wasitcp wasiudp wasiver; do
  src="$here/test/fixtures/component/$name"
  out="$here/test/fixtures/component/$name.component.wasm"
  ( cd "$src" && cargo build --release --target wasm32-unknown-unknown )
  core="$src/target/wasm32-unknown-unknown/release/$name.wasm"
  n="$(wasm-tools print "$core" | grep -c '(import' || true)"
  case "$no_import" in
    *" $name "*)
      [ "$n" = "0" ] || {
        echo "$name core module has $n imports; expected none" >&2; exit 1; } ;;
    *)
      [ "$n" != "0" ] || {
        echo "$name core module imports nothing; expected an import" >&2; exit 1; } ;;
  esac
  wasm-tools component new "$core" -o "$out"
  wasm-tools validate --features component-model "$out"
  echo "built $out"
done

# Real components: a normal Rust `fn main` built for wasm32-wasip2 is already a
# wasi:cli/command component (wasmtime runs it directly), so there is no
# `component new` step. These are the differential fixtures.
rustup target add wasm32-wasip2 >/dev/null 2>&1 || true
for name in realupper realcat argv envvar exitcode catcat filewrite; do
  src="$here/test/fixtures/component/$name"
  out="$here/test/fixtures/component/$name.component.wasm"
  ( cd "$src" && cargo build --release --target wasm32-wasip2 )
  cp "$src/target/wasm32-wasip2/release/$name.wasm" "$out"
  wasm-tools validate --features component-model "$out"
  echo "built $out"
done
