#!/bin/bash
# Build the scratch first-write trees: each arm's commit exported with git
# archive, the untracked fixtures copied, patch.py applied, compiled.
# Never timed; never an arm of the rounds.
set -e
H=$(cd $(dirname $0) && pwd)
P=/Users/benoitc/Projects
mk() { # name repo sha kind
  local d=$P/erlang_wasm-arb-inst-$1
  rm -rf $d; mkdir -p $d
  (cd $P/$2 && git archive $3 | tar -x -C $d)
  echo $3 > $d/ARB_SOURCE_SHA
  cp -R $P/$2/test/fixtures/lang/{lua_reactor.wasm,py_reactor.wasm,py_reactor_lib,python.wasm,qjs.wasm,qjs_reactor.wasm} $d/test/fixtures/lang/
  [ -f $P/$2/priv/wasi_file_nif.so ] && [ $4 = a ] && cp $P/$2/priv/wasi_file_nif.so $d/priv/
  python3 $H/patch.py $d $4
  (cd $d && rebar3 compile 2>&1 | tail -2)
}
mk a3 erlang_wasm-shared-pages 9fcf3a817911baffa52415cd280b0789eeb308e1 a
mk a4 erlang_wasm-tlb2 9230dbfbe214b5f44c4b5c1e0448a861bb31f581 a
mk b erlang_wasm-mmap 435bace37e37d92c15d867bac8e812df7835357a b
