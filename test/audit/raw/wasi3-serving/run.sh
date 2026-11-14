#!/bin/bash
# Main and the candidate, each in a fresh VM per sample, interleaved, both
# orders, each round started at a one-minute load below 8.
S=$(cd "$(dirname "$0")" && pwd)
MAIN=${MAIN:?the main tree}; CAND=${CAND:?the candidate tree}
F=/Users/benoitc/Projects/erlang_wasm-wasi3/test/fixtures
P2=$F/wasmtime-p2-serve/p2_cli_serve_hello_world.component.wasm
P3=$F/wasmtime-p3-serve/p3_cli_serve_hello_world.component.wasm
ECHO=$F/wasmtime-p3-serve/p3_http_echo.component.wasm
for i in 1 2 3 4 5 6; do
  until awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l < 8)}'; do sleep 20; done
  echo "round $i load $(sysctl -n vm.loadavg | awk '{print $2}')"
  if [ $((i % 2)) = 1 ]; then o="main cand"; else o="cand main"; fi
  for t in $o; do
    if [ "$t" = main ]; then d=$MAIN; else d=$CAND; fi
    run() { (cd "$d" && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa "$S" -run "$1" main "$2"); }
    echo "$t serve02 $(run sbench $P2)"
    echo "$t listen02 $(run lbench $P2)"
    echo "$t listen03 $(run lbench $P3)"
    echo "$t firstbyte $(run fbench $ECHO)"
  done
done
