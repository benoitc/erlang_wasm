#!/bin/bash
R=/Users/benoitc/Projects/erlang_wasm-pi-results; S=$(dirname "$0")
F=/Users/benoitc/Projects/erlang_wasm/test/fixtures/wasmtime-p2-serve/p2_cli_serve_hello_world.component.wasm
for i in 1 2 3 4 5 6; do
  until awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l < 8)}'; do sleep 20; done
  if [ $((i % 2)) = 1 ]; then o="main cand"; else o="cand main"; fi
  for t in $o; do
    if [ $t = main ]; then p="$R/iw-main/_build/default/lib/*/ebin"; else p="/Users/benoitc/Projects/erlang_wasm-http/_build/default/lib/*/ebin"; fi
    echo "$t $(erl -noshell +S 10:10 -pa $p -pa $S -run lbench main $F)"
  done
done
