#!/bin/bash
# The gate rounds. A cell is one metric, guest and tier run on all three arms,
# each in a fresh VM, in the round's order. The cell starts once load1 < 8; if
# load1 at the end of its last arm is >= 8 the cell is redone, its files kept
# under redone/. Run build.sh and prime.sh first.
#   ROUNDS="1 2" ./rounds.sh
source $(dirname $0)/lib.sh
ROUNDS=${ROUNDS:-"1 2 3 4 5 6"}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-6}
mkdir -p $OUT/raw $OUT/log $OUT/redone
LOADS=$OUT/loads.tsv
[ -f $LOADS ] || printf "round\tmetric\tguest\ttier\tarm\tattempt\tsecs\tload_start\tload_end\n" > $LOADS

cmd() { # metric guest tier arm file
  local c=none
  [ "$3" = compiled ] && c=$(cachedir $4)
  case $1 in
    split|steady) erlrun $4 -run requestbench main $1 $2 $3 off $c $5;;
    density)      erlrun $4 -run densitybench main density $2 $5;;
    real)         erlrun $4 -run realbench main qjs > $5 2>&1;;
  esac
}

cell() { # round metric guest tier
  local r=$1 m=$2 g=$3 tier=$4 a=0 le dir=$OUT/raw/r$1
  mkdir -p $dir
  while [ $a -lt $MAX_ATTEMPTS ]; do
    a=$((a+1))
    wait_load >> $OUT/log/wait.log
    for t in $(order $r); do
      local f=$dir/${m}_${g}_${tier}_$t.terms ls t0
      rm -f $f; ls=$(load1); t0=$(date +%s)
      echo "== r$r $m $g $tier $t attempt $a $(uptime)" >> $OUT/log/r$r.log
      cmd $m $g $tier $t $f >> $OUT/log/r$r.log 2>&1
      le=$(load1)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" $r $m $g $tier $t $a $(( $(date +%s) - t0 )) $ls $le >> $LOADS
    done
    if over $le; then
      mkdir -p $OUT/redone/r$r.$m.$g.$tier.$a
      mv $dir/${m}_${g}_${tier}_*.terms $OUT/redone/r$r.$m.$g.$tier.$a/
      echo "redo r$r $m $g $tier: end load $le"
    else
      echo "r$r $m $g $tier ok (attempt $a, end load $le) $(date +%H:%M)"
      return 0
    fi
  done
  echo "r$r $m $g $tier VOID after $MAX_ATTEMPTS attempts" | tee -a $OUT/void.txt
}

for r in $ROUNDS; do
  for tier in compiled interp; do cell $r split py_entry $tier; done
  for g in py_entry py qjs lua; do for tier in compiled interp; do
    cell $r steady $g $tier
  done; done
  for g in py_entry py qjs lua; do cell $r density $g -; done
  cell $r real qjs -
  echo "round $r done $(date)"
done
echo ROUNDS_DONE
