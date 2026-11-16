#!/bin/bash
# Main and the candidate, a fresh VM per sample, five rounds interleaved, both
# orders, each round started at a one-minute load below 8. `async' is the gate
# (read-future and sum-stream, us); `sync' is recorded, not gated.
S=$(cd "$(dirname "$0")" && pwd)
MAIN=${MAIN:?the main tree}; CAND=${CAND:?the candidate tree}
F=$CAND/test/fixtures/component
erlc -o "$S" "$S"/asyncb.erl "$S"/syncb.erl
for i in 1 2 3 4 5; do
  until awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l < 8)}'; do sleep 20; done
  echo "round $i load $(sysctl -n vm.loadavg | awk '{print $2}')"
  if [ $((i % 2)) = 1 ]; then o="main cand"; else o="cand main"; fi
  for t in $o; do
    if [ "$t" = main ]; then d=$MAIN; else d=$CAND; fi
    run() { (cd "$d" && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa "$S" -run "$1" main "$2" 2>&1 | tail -1); }
    echo "$t async $(run asyncb $F/asyncval.component.wasm)"
    echo "$t sync $(run syncb $F/composed.component.wasm)"
  done
done
