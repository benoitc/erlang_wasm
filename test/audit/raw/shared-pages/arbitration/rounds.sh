#!/bin/bash
# The arbitration rounds. A cell is one metric (and guest and tier) run on
# all four arms, each in a fresh VM, in the Williams order of the round. The
# cell starts once load1 < 8; if load1 at the end of its last arm is >= 8 the
# cell is redone, its files kept under redone/. Run prime.sh first.
#   ROUNDS="1 2" ./rounds.sh      # a subset; default all eight
#   SMOKE=1 ./rounds.sh           # one round, tiny counts, no load gate,
#                                 # into results-smoke; never a sample
source $(dirname $0)/lib.sh
K=50; RN=200; RL=20
if [ "$SMOKE" = 1 ]; then
  export ARB_SMOKE=1
  OUT=$ARB/results-smoke; ROUNDS=${ROUNDS:-1}; MAX_ATTEMPTS=1
  LOAD_MAX=1000; K=2; RN=3; RL=1
  cachedir() { echo $HOME/.cache/wasm-arb-smoke/$1; }
else
  unset ARB_SMOKE
fi
ROUNDS=${ROUNDS:-"1 2 3 4 5 6 7 8"}
for t in $ARMS; do
  if [ "$SMOKE" = 1 ]; then mkdir -p $(cachedir $t)
  elif [ ! -d $(cachedir $t) ]; then echo "no cache for $t: run prime.sh"; exit 1
  fi
done
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
    sharing)      erlrun $4 -run optbshare main $2 $K $5;;
    restore)      erlrun $4 -run restorebench main all $RN $RL $5;;
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
      local f=$dir/${m}_${g}_${tier}_$t.terms ls
      rm -f $f
      ls=$(load1); local t0=$(date +%s)
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
  for m in split steady; do for g in $GUESTS; do for tier in interp compiled; do
    cell $r $m $g $tier
  done; done; done
  for g in $GUESTS; do cell $r density $g -; done
  for g in $GUESTS; do cell $r sharing $g -; done
  cell $r restore all -
  cell $r real qjs -
  echo "round $r done $(date)"
done
echo ROUNDS_DONE
