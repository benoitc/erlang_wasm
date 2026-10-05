#!/bin/bash
# Metric 3, first-write cost per request, on the scratch instrumented trees
# (inst/make.sh). Separate from the timed arms; one pass, 200 requests per
# cell after the usual warm-up, each in a fresh VM.
#   SMOKE=1 ./fw.sh    # tiny counts, no load gate, into results-smoke/fw
source $(dirname $0)/lib.sh
if [ "$SMOKE" = 1 ]; then
  export ARB_SMOKE=1; OUT=$ARB/results-smoke; LOAD_MAX=1000
  cachedir() { echo $HOME/.cache/wasm-arb-smoke/$1; }
else
  unset ARB_SMOKE
fi
mkdir -p $OUT/fw
for t in inst-a3 inst-a4 inst-b; do
  c=$(cachedir $t); mkdir -p $c
  for g in $GUESTS; do for tier in interp compiled; do
    wait_load >> $OUT/fw/wait.log
    cc=none; [ $tier = compiled ] && cc=$c
    echo "== $t $g $tier $(uptime)" >> $OUT/fw/log.txt
    erlrun $t -run requestbench main firstwrite $g $tier off $cc \
      $OUT/fw/${g}_${tier}_$t.terms >> $OUT/fw/log.txt 2>&1
  done; done
done
echo FW_DONE
