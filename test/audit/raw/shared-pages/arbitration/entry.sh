#!/bin/bash
# The hornbeam-style path: CPython with an entry captured into the image, one
# function call per request (reactorlib's py_entry). Arms base, a4, b; one
# Williams pass over three arms (all six orderings). Same load gate as
# rounds.sh. Primes each arm's existing cache for py_entry first (no emptying:
# the entry's functions are a different cache key).
source $(dirname $0)/lib.sh
unset ARB_SMOKE
OUT=$ARB/results-entry
ARMS="base a4 b"
G=py_entry
MAX_ATTEMPTS=6
order() {
  case $1 in
    1) echo "base a4 b";; 2) echo "a4 b base";; 3) echo "b base a4";;
    4) echo "base b a4";; 5) echo "a4 base b";; 6) echo "b a4 base";;
  esac
}
mkdir -p $OUT/raw $OUT/log $OUT/redone $OUT/prime
LOADS=$OUT/loads.tsv
[ -f $LOADS ] || printf "round\tmetric\tguest\ttier\tarm\tattempt\tsecs\tload_start\tload_end\n" > $LOADS

for t in $ARMS; do
  ( erlrun $t -run requestbench main steady $G interp off none none
    erlrun $t -run requestbench main steady $G compiled off $(cachedir $t) none
    echo PRIME_DONE ) > $OUT/prime/$t.txt 2>&1 &
done; wait
grep -L PRIME_DONE $OUT/prime/*.txt; grep -l "failed:\|VOID" $OUT/prime/*.txt
echo PRIMED

cmd() { # metric tier arm file
  local c=none
  [ "$2" = compiled ] && c=$(cachedir $3)
  case $1 in
    split|steady) erlrun $3 -run requestbench main $1 $G $2 off $c $4;;
    density)      erlrun $3 -run densitybench main density $G $4;;
    sharing)      erlrun $3 -run optbshare main $G 50 $4;;
  esac
}
cell() { # round metric tier
  local r=$1 m=$2 tier=$3 a=0 le dir=$OUT/raw/r$1
  mkdir -p $dir
  while [ $a -lt $MAX_ATTEMPTS ]; do
    a=$((a+1))
    wait_load >> $OUT/log/wait.log
    for t in $(order $r); do
      local f=$dir/${m}_${G}_${tier}_$t.terms ls t0
      rm -f $f; ls=$(load1); t0=$(date +%s)
      echo "== r$r $m $tier $t attempt $a $(uptime)" >> $OUT/log/r$r.log
      cmd $m $tier $t $f >> $OUT/log/r$r.log 2>&1
      le=$(load1)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" $r $m $G $tier $t $a $(( $(date +%s) - t0 )) $ls $le >> $LOADS
    done
    if over $le; then
      mkdir -p $OUT/redone/r$r.$m.$tier.$a
      mv $dir/${m}_${G}_${tier}_*.terms $OUT/redone/r$r.$m.$tier.$a/
      echo "redo r$r $m $tier: end load $le"
    else
      echo "r$r $m $tier ok (attempt $a, end load $le) $(date +%H:%M)"; return 0
    fi
  done
  echo "r$r $m $tier VOID after $MAX_ATTEMPTS attempts" | tee -a $OUT/void.txt
}
for r in 1 2 3 4 5 6; do
  for m in split steady; do for tier in interp compiled; do cell $r $m $tier; done; done
  cell $r density -
  cell $r sharing -
  echo "round $r done $(date)"
done
echo ENTRY_DONE
