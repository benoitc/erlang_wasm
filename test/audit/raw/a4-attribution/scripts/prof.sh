#!/bin/bash
# Profiles, one fresh VM each, load-gated (start < 8; redone once if end >= 8).
#   STEPS="prof tprof bigword count regions cold" ./prof.sh
source $(dirname $0)/lib.sh
STEPS=${STEPS:-"prof tprof bigword count regions"}
GUESTS=${GUESTS:-"py_entry qjs lua py"}
mkdir -p $OUT/prof $OUT/log
one() { # step guest arm n
  local f=$OUT/prof/$1_$2_$3.terms c=$(cachedir $3) a=0
  while [ $a -lt 3 ]; do
    a=$((a+1)); wait_load >> $OUT/log/wait.log
    rm -f $f; echo "== $1 $2 $3 attempt $a $(uptime)" >> $OUT/log/prof.log
    local ls=$(load1)
    if [ ${1#foot} != $1 ]; then
      erlrun $3 -run optbshare main $2 $4 $f >> $OUT/log/prof.log 2>&1
    elif [ $1 = cold ]; then
      c=$HOME/.cache/wasm-attr/cold-$3-$2; rm -rf $c; mkdir -p $c
      ARB_SMOKE=1 erlrun $3 -run requestbench main steady $2 compiled off $c $f >> $OUT/log/prof.log 2>&1
      rm -rf $c
    else
      ATTR_N=$4 erlrun $3 -run attrbench main $1 $2 compiled off $c $f >> $OUT/log/prof.log 2>&1
    fi
    local le=$(load1)
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" $1 $2 $3 $a $ls $le >> $OUT/prof/loads.tsv
    over $le || break
    mv $f $f.redo$a 2>/dev/null
  done
}
for s in $STEPS; do for g in $GUESTS; do
  case $s in
    prof)    for t in base main null; do one prof $g $t 200; done;;
    tprof)   for t in base main; do one tprof $g $t 30; done;;
    bigword) for t in base main; do one bigword $g $t 3; done;;
    count)   one count $g inst 100;;
    regions) one regions $g inst 30;;
    cold)    for t in base main; do one cold $g $t 0; done;;
    foot)    for r in 1 2; do for t in base main null; do one foot$r $g $t 50; done; done;;
  esac
  echo "$s $g done $(date +%H:%M)"
done; done
echo PROF_DONE
