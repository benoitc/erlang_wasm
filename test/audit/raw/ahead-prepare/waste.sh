#!/bin/bash
# Gate 5 runs on the inst.py scratch trees, never timed: requestbench paced,
# restore_ahead on, logging each request's pages to $OUT/waste/<cell>_<arm>.log.
source $(dirname $0)/lib.sh
W=$OUT/waste; mkdir -p $W
for g in ${GUESTS:-py_entry py qjs lua}; do for tier in ${TIERS:-interp compiled}; do
  for t in main cand; do
    c=none; [ $tier = compiled ] && c=$(cachedir $t)
    f=$W/${g}_${tier}_$t.log; rm -f $f
    (cd $P/erlang_wasm-ap-inst-$t && AP_LOG=$f ERL_LIBS=_build/default/lib erl -noshell +S 10:10 \
       -pa _build/default/lib/wasm/ebin -pa bench/arb \
       -run requestbench main paced $g $tier on $c none) > $W/${g}_${tier}_$t.out 2>&1
    echo "$g $tier $t $(grep -c . $f) lines $(grep -o 'median_us => [0-9.]*' $W/${g}_${tier}_$t.out)"
  done
done; done
$(dirname $0)/waste.escript $W | tee $W/waste.txt
