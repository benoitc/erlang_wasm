#!/bin/bash
# Gates 5 and 6 after the two fixes: main bd8b7b6, cand, null (bd8b7b6 again),
# interleaved, 5 rounds, odd rounds main-cand-null, even rounds null-cand-main.
# A run starts only below a one-minute load of 8; a restore run that ends at 8
# or more is redone (up to 3 attempts). Churn runs raise the load themselves,
# so they are recorded, not redone.
OUT=/Users/benoitc/Projects/erlang_wasm/test/audit/raw/pool-image/rerun
TREE=/Users/benoitc/Projects/ewbench
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
below8() { awk -v l="$(load1)" 'BEGIN{exit !(l < 8)}'; }
wait_quiet() { until below8; do sleep 20; done; }
erlrun() { (cd "$TREE-$1" && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa bench/paths "${@:2}"); }
cell() { # name redo cmd...
  local name=$1 redo=$2; shift 2; mkdir -p "$OUT/$name"
  for r in 1 2 3 4 5; do
    if [ $((r % 2)) = 1 ]; then arms="main cand null"; else arms="null cand main"; fi
    for a in $arms; do
      for attempt in 1 2 3; do
        wait_quiet; l0=$(load1)
        rm -f "$OUT/$name/$a-r$r.terms"
        erlrun $a "$@" "$OUT/$name/$a-r$r.terms" > "$OUT/$name/$a-r$r.out" 2>&1
        l1=$(load1)
        echo "$name r$r $a attempt$attempt load $l0 -> $l1" >> "$OUT/$name/loads.log"
        if [ "$redo" = no ] || awk -v l="$l1" 'BEGIN{exit !(l < 8)}'; then break; fi
      done
    done
  done
}
cell restore yes -run restorebench main all 200 20
for spec in "py_entry none 2000" "py_entry lua 2000" "py none 1000" "py lua 1000" \
            "qjs none 2000" "qjs lua 2000" "lua none 4000" "lua qjs 4000"; do
  set -- $spec
  cell "churn-$1-$2" no -run densitybench main churn $1 10 $2 $3 _build/codecache
done
echo ALLDONE >> "$OUT/progress.log"
