#!/usr/bin/env bash
# Build wasmtime's native WASI 0.2 test programs (the p2_* command components)
# for the interop track (test/wasm_wasi2_p2_SUITE). These are wasmtime's own
# `test-programs`, authored against WASI 0.2 directly (no preview1 adapter), each
# a self-asserting command component: exit 0 on success, trap or non-zero on
# failure.
#
# They are NOT vendored: at ~7.6 MB each in wasmtime's debug profile they are far
# too large to commit, so like the upstream test suites (see `make suites`) they
# are built on demand and the suite skips when they are absent. This clones
# wasmtime at a pinned tag, lets its `test-programs-artifacts` crate compile and
# componentize every program (to wasm32-wasip1, then the command/reactor/proxy
# adapters via wit-component), then strips each command component (7.6 MB -> ~115
# KB) into test/fixtures/wasmtime-p2/.
#
# Needs rustup's wasm32-wasip1 target, cargo, and wasm-tools. The p2_cli_serve_*
# reactors go in a separate `-serve` dir (served through run_serve by
# wasm_wasi2_serve_SUITE, not run as commands); the p2_api_* and p2_tls_* proxy/tls
# programs are still left out.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

tag="v48.0.1"
src="${WASMTIME_P2_SRC:-$here/.wasmtime-src}"
dest="$here/test/fixtures/wasmtime-p2"

command -v cargo >/dev/null      || { echo "cargo not found" >&2; exit 1; }
command -v wasm-tools >/dev/null || { echo "wasm-tools not found" >&2; exit 1; }
rustup target add wasm32-wasip1 >/dev/null 2>&1 || true

if [ ! -d "$src/wasmtime" ]; then
  echo "cloning wasmtime $tag into $src"
  mkdir -p "$src"
  git clone --depth 1 --branch "$tag" \
      https://github.com/bytecodealliance/wasmtime.git "$src/wasmtime"
fi

cd "$src/wasmtime"
pkg="$(grep -m1 '^name' crates/test-programs/artifacts/Cargo.toml \
         | sed 's/.*= *"//; s/"//')"
echo "building $pkg (compiles + componentizes every test program)"
cargo build -p "$pkg"

out="$(find target -type d -path '*wasm32-wasip1*' -name debug \
         -exec test -e '{}/p2_random.component.wasm' ';' -print | head -1)"
[ -n "$out" ] || { echo "no componentized p2_* output found" >&2; exit 1; }

# Command programs (exit-0 oracles) go in $dest, driven by wasm_wasi2_p2_SUITE via
# run_command. The reactor serve programs export wasi:http/incoming-handler and are
# served, not run, so they go in a separate dir the command runner never globs;
# wasm_wasi2_serve_SUITE drives them through wasi_preview2:run_serve.
serve_dest="$dest-serve"
mkdir -p "$dest" "$serve_dest"
n=0
s=0
for f in "$out"/p2_*.component.wasm; do
  base="$(basename "$f")"
  case "$base" in
    p2_cli_serve_*)
      wasm-tools strip "$f" -o "$serve_dest/$base"
      s=$((s + 1))
      continue ;;
    p2_api_*|p2_tls_*) continue ;;  # proxy/tls: not yet driven
  esac
  wasm-tools strip "$f" -o "$dest/$base"
  n=$((n + 1))
done
echo "built $n command components into $dest ($(du -sh "$dest" | cut -f1))"
echo "built $s serve reactors into $serve_dest ($(du -sh "$serve_dest" | cut -f1))"
