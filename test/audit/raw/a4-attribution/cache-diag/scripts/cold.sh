#!/bin/bash
# Cold compile: empty code cache, requestbench steady (ARB_SMOKE) until the
# first request enters generated code. Interleaved: rep x guest, arms rotated.
# Start gated at load1 < 8; end load noted. Each run's cache is copied into
# the arm's cache for the call phase (rep 1 only).
source $(dirname $0)/lib.sh
REPS=${REPS:-"1 2 3"}
GUESTS=${GUESTS:-"lua py_entry qjs py"}
ARMS=(base v0 v1 v2 v3)
mkdir -p $OUT/cold $OUT/log
T=$OUT/cold/loads.tsv
[ -f $T ] || printf "rep\tguest\tarm\tsecs\tload_start\tload_end\tmem_peak\n" > $T
i=0
for r in $REPS; do for g in $GUESTS; do
  i=$((i+1))
  for k in 0 1 2 3 4; do
    a=${ARMS[$(( (k + i + r) % 5 ))]}
    c=$HOME/.cache/wasm-cdiag/cold/$a-$g; rm -rf $c; mkdir -p $c
    f=$OUT/cold/${g}_${a}_r$r.terms; m=$OUT/cold/${g}_${a}_r$r.mem
    wait_load >> $OUT/log/wait.log
    ls=$(load1); t0=$(date +%s)
    echo "== cold r$r $g $a $(uptime)" >> $OUT/log/cold.log
    ARB_SMOKE=1 erlrun $a -run memwatch start $m -run requestbench main steady $g compiled off $c $f >> $OUT/log/cold.log 2>&1
    le=$(load1)
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" $r $g $a $(( $(date +%s) - t0 )) $ls $le $(cat $m) >> $T
    if [ ! -d $OUT/codecache/$a-$g ]; then mkdir -p $OUT/codecache/$a-$g; cp $c/* $OUT/codecache/$a-$g/; fi
    mkdir -p $(cachedir $a); cp -n $c/* $(cachedir $a)/ 2>/dev/null
    rm -rf $c
    echo "cold r$r $g $a $(( $(date +%s) - t0 ))s load $ls..$le $(date +%H:%M)"
  done
done; done
echo COLD_DONE
