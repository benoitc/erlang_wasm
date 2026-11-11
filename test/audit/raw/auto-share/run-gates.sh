#!/bin/bash
# Gates 1 to 3 of "One image for a pool", main (prepare/2) against the
# candidate (automatic sharing): five rounds, odd rounds main first, each run
# in a fresh VM, started at a one-minute load below 8.
MAIN=$1; CAND=$2; OUT=$3
mkdir -p "$OUT"
waitload() { until awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l < 8)}'; do sleep 20; done; }
run() { # tree arm guest args...
  local d=$1; shift
  (cd "$d" && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa bench/paths \
     -run densitybench main "$@" none 2>&1 | grep -A20 "verdict" | tr -s ' ' | tr '\n' ' ')
}
for r in 1 2 3 4 5; do
  if [ $((r % 2)) = 1 ]; then order="main cand"; else order="cand main"; fi
  for g in qjs lua py_entry py; do
    for mode in "workers $g 50 off" "capture $g 4" "pool $g 10"; do
      for t in $order; do
        if [ $t = main ]; then d=$MAIN; else d=$CAND; fi
        waitload
        echo "r=$r $t $mode load=$(sysctl -n vm.loadavg | awk '{print $2}') $(run $d $mode)" >> "$OUT/gates.log"
      done
    done
  done
done
