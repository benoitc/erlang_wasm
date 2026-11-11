#!/bin/bash
S=$(dirname "$0"); R=/Users/benoitc/Projects/erlang_wasm-pi-results
F=/Users/benoitc/Projects/erlang_wasm-wasi3/test/fixtures/component/asyncval.component.wasm
for i in 1 2 3 4 5 6; do
  until awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l < 8)}'; do sleep 20; done
  if [ $((i % 2)) = 1 ]; then o="main cand"; else o="cand main"; fi
  for t in $o; do
    if [ "$t" = main ]; then d=$R/async-main; else d=/Users/benoitc/Projects/erlang_wasm-wasi3; fi
    echo "$t $(cd $d && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa $S -run asyncb main $F 2>&1 | tail -1)"
  done
done
