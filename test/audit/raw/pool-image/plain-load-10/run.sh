#!/bin/bash
# Gate 5, plain load_snapshot, ten rounds: main bd8b7b6, cand 61e4ef1, null
# bd8b7b6. Odd rounds main-cand-null, even rounds null-cand-main. Each tree
# runs once unrecorded first. Runs start below load 8 and are redone (up to 3
# attempts) when they end at 8 or more.
OUT=/Users/benoitc/Projects/erlang_wasm/test/audit/raw/pool-image/plain-load-10
TREE=/Users/benoitc/Projects/ewbench
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
below8() { awk -v l="$(load1)" 'BEGIN{exit !(l < 8)}'; }
wait_quiet() { until below8; do sleep 20; done; }
erlrun() { (cd "$TREE-$1" && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa bench/paths "${@:2}"); }
for a in main cand null; do wait_quiet; erlrun $a -run restorebench main plain 200 2000 "$OUT/warm-$a.terms" > "$OUT/warm-$a.out" 2>&1; done
for r in 1 2 3 4 5 6 7 8 9 10; do
  if [ $((r % 2)) = 1 ]; then arms="main cand null"; else arms="null cand main"; fi
  for a in $arms; do
    for attempt in 1 2 3; do
      wait_quiet; l0=$(load1)
      rm -f "$OUT/$a-r$r.terms"
      erlrun $a -run restorebench main plain 200 2000 "$OUT/$a-r$r.terms" > "$OUT/$a-r$r.out" 2>&1
      l1=$(load1)
      echo "r$r $a attempt$attempt load $l0 -> $l1" >> "$OUT/loads.log"
      awk -v l="$l1" 'BEGIN{exit !(l < 8)}' && break
    done
  done
done
echo DONE >> "$OUT/loads.log"
