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
#     asyncval   -- async funcs over future<u32> and stream<u8> (the async ABI)
#     asyncimp   -- an async func that awaits an async import (caller-side async)
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

for name in echo vectors counter hostcall hostagg wasirandom wasiclocks wasienv wasiio wasiin wasiiofull wasifs wasisock wasitcp wasiudp wasiver asyncval asyncimp; do
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

# Hand-authored components (WebAssembly component text), for the linker: a two-core
# component whose larger core imports a function from the smaller one, so it links
# only by wiring core to core, never by a host name. `twocore_trap` is the same
# shape but the entry core traps in its start function, so linking fails after the
# provider core is built: the linker must free that core rather than leak it.
# `statecore` has one core with a mutable global exported as `bump`, so a per-request
# cold instance returns 1 every call and a reused one would climb: it proves the
# worker gives each request a fresh component instance.
for name in twocore twocore_trap statecore renamedexport; do
  wat="$here/test/fixtures/component/$name/$name.wat"
  out="$here/test/fixtures/component/$name.component.wasm"
  wasm-tools parse "$wat" -o "$out"
  wasm-tools validate --features component-model "$out"
  echo "built $out"
done

# A bare core module (not a component) whose start function traps, the baseline
# for the linker leak test: one failed instantiate leaves one instance behind.
trapwat="$here/test/fixtures/component/trapcore/trapcore.wat"
trapout="$here/test/fixtures/component/trapcore.wasm"
wasm-tools parse "$trapwat" -o "$trapout"
wasm-tools validate "$trapout"
echo "built $trapout"

# The wasmtime preview1->preview2 adapter, pinned to the wasmtime we test against.
# It turns a wasm32-wasip1 program into a preview2 command component (many core
# modules linked by the component graph), which is how the official wasi-testsuite
# is reused. Committed at test/fixtures/component/wasi_snapshot_preview1.command.wasm.
adapter="$here/test/fixtures/component/wasi_snapshot_preview1.command.wasm"
adapter_ver="v48.0.1"
if [ ! -f "$adapter" ]; then
  curl -fsSL -o "$adapter" \
    "https://github.com/bytecodealliance/wasmtime/releases/download/$adapter_ver/wasi_snapshot_preview1.command.wasm"
  echo "fetched $adapter ($adapter_ver)"
fi
