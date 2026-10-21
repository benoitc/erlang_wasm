#!/bin/bash
# Gates 1-4 on the final pool-image code: main bd8b7b6, cand 61e4ef1 with the
# absolute-cache harness, null bd8b7b6 again. Same protocol as the first run:
# 5 rounds, odd main-cand-null, even null-cand-main; a run starts below load 8
# and is redone (up to 3 attempts) when it ends at 8 or more. Each tree fills
# its code cache with one unrecorded compiled run per guest first.
OUT=/Users/benoitc/Projects/erlang_wasm/test/audit/raw/pool-image/final
TREE=/Users/benoitc/Projects/ewbench
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
below8() { awk -v l="$(load1)" 'BEGIN{exit !(l < 8)}'; }
wait_quiet() { until below8; do sleep 20; done; }
erlrun() { (cd "$TREE-$1" && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa bench/paths "${@:2}"); }
cell() {
  local name=$1; shift; mkdir -p "$OUT/$name"
  for r in 1 2 3 4 5; do
    if [ $((r % 2)) = 1 ]; then arms="main cand null"; else arms="null cand main"; fi
    for a in $arms; do
      for attempt in 1 2 3; do
        wait_quiet; l0=$(load1)
        rm -f "$OUT/$name/$a-r$r.terms"
        erlrun $a "$@" "$OUT/$name/$a-r$r.terms" > "$OUT/$name/$a-r$r.out" 2>&1
        l1=$(load1)
        echo "$name r$r $a attempt$attempt load $l0 -> $l1" >> "$OUT/$name/loads.log"
        awk -v l="$l1" 'BEGIN{exit !(l < 8)}' && break
      done
    done
  done
  echo "$name done" >> "$OUT/progress.log"
}
for g in py_entry py qjs lua; do for a in main cand null; do
  wait_quiet; erlrun $a -run requestbench main steady $g compiled off _build/codecache none > "$OUT/warm-$g-$a.out" 2>&1
done; done
echo "warm done" >> "$OUT/progress.log"
for g in py_entry py qjs lua; do
  cell "workers-$g" -run densitybench main workers $g 50 off
  cell "capture-$g" -run densitybench main capture $g 4
  cell "pool-$g" -run densitybench main pool $g 10
  cell "copy-$g" -run densitybench main copy $g 200
  cell "req-$g-compiled" -run requestbench main steady $g compiled off _build/codecache
  cell "req-$g-interp" -run requestbench main steady $g interp off _build/codecache
done
echo ALLDONE >> "$OUT/progress.log"
