#!/bin/bash
# setup.sh ARM...: fixtures, build and harness for each arm's tree, and its
# manifest lines. The harness is main's bench/paths at 14d3d81, plus the
# attribution's attrbench (saturated mode) and memwatch.
set -e
source $(dirname $0)/lib.sh
FILES="benchlib reactorlib barrier_adapter requestbench restorebench densitybench realbench"
for t in "$@"; do
  d=$(tree $t)
  for f in lua_reactor.wasm py_reactor.wasm python.wasm qjs.wasm qjs_reactor.wasm; do
    cp -n $P/erlang_wasm-shared-pages/test/fixtures/lang/$f $d/test/fixtures/lang/ || true
  done
  [ -d $d/test/fixtures/lang/py_reactor_lib ] || cp -R $P/erlang_wasm-shared-pages/test/fixtures/lang/py_reactor_lib $d/test/fixtures/lang/
  (cd $d && rebar3 compile > $R/build-$t.log 2>&1)
  mkdir -p $d/bench/om
  for f in $FILES; do cp $P/erlang_wasm-om-main/bench/paths/$f.erl $d/bench/om/; done
  cp $R/scripts/attrbench.erl $R/scripts/memwatch.erl $d/bench/om/
  (cd $d && erlc -o bench/om -pa _build/default/lib/wasm/ebin bench/om/*.erl)
  {
    echo "== $t $d"
    echo "head $(git -C $d rev-parse HEAD)"
    git -C $d status --short src include c_src | sed 's/^/dirty /'
    echo "src_sha $(cat $d/src/*.erl $d/src/worker/*.erl $d/include/*.hrl | shasum -a 256 | cut -c1-16)"
    echo "abi $(grep -- '-define(ABI' $d/src/wasm_jit.erl)"
    (cd $d/bench/om && shasum -a 256 *.erl)
  } > $R/manifest-$t.txt
  echo "setup $t done"
done
