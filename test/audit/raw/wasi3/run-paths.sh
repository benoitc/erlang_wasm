#!/bin/bash
S=$(dirname "$0"); R=/Users/benoitc/Projects/erlang_wasm-pi-results
SERVE=/Users/benoitc/Projects/erlang_wasm/test/fixtures/wasmtime-p2-serve/p2_cli_serve_hello_world.component.wasm
CMD=/Users/benoitc/Projects/erlang_wasm/test/fixtures/wasmtime-p2/p2_cli_hello_stdout.component.wasm
for i in 1 2 3 4 5 6; do
  until awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l < 8)}'; do sleep 20; done
  if [ $((i % 2)) = 1 ]; then o="main cand"; else o="cand main"; fi
  for t in $o; do
    if [ "$t" = main ]; then d=$R/w3-main; else d=/Users/benoitc/Projects/erlang_wasm-wasi3; fi
    echo "$t serve $(cd $d && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa $S -run lbench main $SERVE)"
    echo "$t cmd $(cd $d && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa $S -run cmdbench main $CMD)"
  done
done
