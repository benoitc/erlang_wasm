#!/bin/bash
# Diagnostic for plain load_snapshot (2000 loads a run), gate 5 after 61e4ef1 (file tables decoded straight into packed words): main
# bd8b7b6, cand 61e4ef1, null (bd8b7b6 again), interleaved, 5 rounds, odd
# rounds main-cand-null, even rounds null-cand-main. Each tree first runs once
# unrecorded, which captures and files its images. A run starts only below a
# one-minute load of 8 and is redone (up to 3 attempts) if it ends at 8 or more.
OUT=/Users/benoitc/Projects/erlang_wasm/test/audit/raw/pool-image/rerun2
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
cell plain-load yes -run restorebench main plain 200 2000
echo PLAINDONE >> "$OUT/progress.log"
