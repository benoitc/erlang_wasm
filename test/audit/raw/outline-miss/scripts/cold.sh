#!/bin/bash
# Gate 1, cold compile: an empty code cache, requestbench steady (ARB_SMOKE)
# until the first request enters generated code; entry_ms is the figure. A
# cell is one rep of one guest on the three arms, rotated; it starts below
# load 8 and is redone when the load at the end of its last arm is 8 or more.
# The first clean run's cache becomes the arm's cache for the timed rounds.
source $(dirname $0)/lib.sh
REPS=${REPS:-"1 2 3"}
GUESTS=${GUESTS:-"lua py_entry qjs py"}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}
ARMS=(main cand one)
mkdir -p $OUT/cold $OUT/log $OUT/redone
T=$OUT/cold/loads.tsv
[ -f $T ] || printf "rep\tguest\tarm\tattempt\tsecs\tload_start\tload_end\tmem_peak\n" > $T
i=0
for r in $REPS; do for g in $GUESTS; do
  i=$((i+1)); a=0
  while [ $a -lt $MAX_ATTEMPTS ]; do
    a=$((a+1))
    wait_load >> $OUT/log/wait.log
    for k in 0 1 2; do
      t=${ARMS[$(( (k + i + r) % 3 ))]}
      c=$HOME/.cache/wasm-om/cold/$t-$g; rm -rf $c; mkdir -p $c
      f=$OUT/cold/${g}_${t}_r$r.terms; m=$OUT/cold/${g}_${t}_r$r.mem
      rm -f $f $m
      ls=$(load1); t0=$(date +%s)
      echo "== cold r$r $g $t attempt $a $(uptime)" >> $OUT/log/cold.log
      ARB_SMOKE=1 erlrun $t -run memwatch start $m -run requestbench main steady $g compiled off $c $f >> $OUT/log/cold.log 2>&1
      le=$(load1)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" $r $g $t $a $(( $(date +%s) - t0 )) $ls $le $(cat $m) >> $T
      echo "cold r$r $g $t $(( $(date +%s) - t0 ))s load $ls..$le $(date +%H:%M)"
    done
    if over $le; then
      mkdir -p $OUT/redone/cold.r$r.$g.$a
      for t in ${ARMS[@]}; do mv $OUT/cold/${g}_${t}_r$r.terms $OUT/cold/${g}_${t}_r$r.mem $OUT/redone/cold.r$r.$g.$a/; done
      echo "redo cold r$r $g: end load $le"
    else
      break
    fi
  done
  for t in ${ARMS[@]}; do
    c=$HOME/.cache/wasm-om/cold/$t-$g
    if [ ! -d $HOME/.cache/wasm-om/codecache/$t-$g ]; then mkdir -p $HOME/.cache/wasm-om/codecache/$t-$g; cp $c/* $HOME/.cache/wasm-om/codecache/$t-$g/; fi
    mkdir -p $(cachedir $t); cp -n $c/* $(cachedir $t)/ 2>/dev/null
    rm -rf $c
  done
done; done
echo COLD_DONE
