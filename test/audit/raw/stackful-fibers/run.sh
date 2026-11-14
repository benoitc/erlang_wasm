#!/bin/bash
# Main and the candidate, a fresh VM per sample, six rounds interleaved, both
# orders, each round started at a one-minute load below 8.
S=$(cd "$(dirname "$0")" && pwd)
MAIN=${MAIN:?the main tree}; CAND=${CAND:?the candidate tree}
F=$CAND/test/fixtures
VAL=$F/component/asyncval.component.wasm
CMD=$F/wasmtime-p2/p2_cli_hello_stdout.component.wasm
P2=$F/wasmtime-p2-serve/p2_cli_serve_hello_world.component.wasm
P3=$F/wasmtime-p3-serve/p3_cli_serve_hello_world.component.wasm
for i in 1 2 3 4 5 6; do
  until awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l < 8)}'; do sleep 20; done
  echo "round $i load $(sysctl -n vm.loadavg | awk '{print $2}')"
  if [ $((i % 2)) = 1 ]; then o="main cand"; else o="cand main"; fi
  for t in $o; do
    if [ "$t" = main ]; then d=$MAIN; else d=$CAND; fi
    run() { (cd "$d" && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa "$S" -run "$1" main "$2" 2>&1 | tail -1); }
    echo "$t cmd02 $(run cmdbench $CMD)"
    echo "$t serve02 $(run sbench $P2)"
    echo "$t async $(run asyncb $VAL)"
    echo "$t listen03 $(run lbench $P3)"
  done
done
