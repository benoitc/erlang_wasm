#!/bin/bash
# Compile each arm and the harnesses (from cand's bench/paths, which has the
# paced mode) into bench/arb.
source $(dirname $0)/lib.sh
H=$(tree cand)/bench/paths
for t in $ARMS; do
  d=$(tree $t)
  (cd $d && rebar3 compile >/dev/null 2>&1 && mkdir -p bench/arb &&
   erlc -o bench/arb -pa _build/default/lib/wasm/ebin $H/benchlib.erl \
     $H/reactorlib.erl $H/requestbench.erl $H/barrier_adapter.erl \
     $H/densitybench.erl &&
   echo "$t built $(git -C $d rev-parse --short HEAD) $(git -C $d status --short src | wc -l) dirty")
done
