#!/bin/bash
# The plan's gates. Main against itself first (NULL=1), then main and the
# candidate: each sample a fresh VM at +S 10:10, five rounds, both orders,
# each round started at a one-minute load below 8.
#   1-2. a component worker request, the candidate with an image against the
#        cold path, on statecore, twocore and realupper: at most 0.8x;
#   3.   the cold component path, and a QuickJS reactor restoring its core
#        image per request, the candidate against main: at most 1.03x.
S=$(cd "$(dirname "$0")" && pwd)
MAIN=${MAIN:?the main tree}; CAND=${CAND:?the candidate tree}
QJS=${QJS:?the qjs_reactor.wasm fixture}
for T in "$MAIN" "$CAND"; do (cd "$T" && rebar3 compile >/dev/null 2>&1); done
erlc -o "$S" -pa "$CAND/_build/default/lib/wasm/ebin" "$S"/snapb_adapter.erl "$S"/workerb.erl "$S"/qjsb.erl
run() { (cd "$1" && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa "$S" -run "${@:2}" 2>&1 | tail -1); }
for i in 1 2 3 4 5; do
  until awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l < 8)}'; do sleep 20; done
  echo "round $i load $(sysctl -n vm.loadavg | awk '{print $2}')"
  if [ $((i % 2)) = 1 ]; then o="main cand"; else o="cand main"; fi
  for t in $o; do
    if [ "$t" = main ] || [ -n "$NULL" ]; then d=$MAIN; else d=$CAND; fi
    for f in statecore twocore realupper; do
      echo "$t cold $f $(run "$d" workerb main $f false)"
      if [ "$t" = cand ] && [ -z "$NULL" ]; then
        echo "$t image $f $(run "$d" workerb main $f true)"
      fi
    done
    echo "$t qjs $(run "$d" qjsb main "$QJS")"
  done
done
