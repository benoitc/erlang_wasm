#!/bin/bash
# The breakdown on Linux aarch64: one erlang:29 container per tree, the tree
# copied in (never mounted for writing), built there, both guests run.
#   ./linux.sh paged|mmap
set -euo pipefail
D=$(cd $(dirname $0) && pwd)
ARM=$1
SRC=/Users/benoitc/Projects/erlang_wasm-dens-$ARM
mkdir -p $D/linux
docker run --rm -v $SRC:/src:ro -v $D:/out -w /w erlang:29 bash -c '
  set -e
  mkdir -p /w
  tar -C /src --exclude=./_build/default --exclude=./_build/test --exclude=./_build/cmake \
      --exclude="./priv/*.so" --exclude=./testsuite --exclude=./wasi-testsuite \
      -cf - . | tar -C /w -xf -
  cd /w
  command -v cmake >/dev/null || {
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cmake >/dev/null 2>&1; }
  rebar3 compile 2>&1 | tail -5
  ls priv
  mkdir -p /tmp/eb
  erlc -o bench/arb -pa _build/default/lib/wasm/ebin bench/arb/*.erl
  erlc -o /tmp/eb -pa _build/default/lib/wasm/ebin /out/densbreak.erl
  echo "getconf PAGESIZE $(getconf PAGESIZE) $(uname -m) nproc $(nproc)"
  cat /proc/loadavg
  for g in py py_entry; do
    erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/arb \
        -pa /tmp/eb -run densbreak main $g /out/linux/${g}_'$ARM'.terms \
        > /out/linux/${g}_'$ARM'.txt 2>&1
  done
  cat /proc/loadavg
' 2>&1 | tee $D/linux/build_$ARM.log
