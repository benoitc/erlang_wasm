#!/bin/bash
# Gates 2 to 4. A cell is one metric, guest and tier on all four arms, each in
# a fresh VM; round r rotates the arms by r and reverses them on even rounds.
# A cell starts once load1 < 8 and is redone (files kept under redone/) when
# load1 at the end of its last arm is 8 or more. Run prime.sh and cold.sh
# first. A redo moves the cell's four files by name: the glob the diagnostic
# used (split_${g}_*) swept py_entry's files along with py's.
source $(dirname $0)/lib.sh
ROUNDS=${ROUNDS:-"1 2 3 4 5"}
GUESTS=${GUESTS:-"py_entry qjs lua py"}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-5}
ARMS=(main null cand one)
mkdir -p $OUT/raw $OUT/log $OUT/redone
LOADS=$OUT/loads.tsv
[ -f $LOADS ] || printf "round\tmetric\tguest\ttier\tarm\tattempt\tsecs\tload_start\tload_end\n" > $LOADS
order() {
  local r=$1 o=() k
  for k in 0 1 2 3; do o+=(${ARMS[$(( (k + r) % 4 ))]}); done
  if [ $((r % 2)) -eq 0 ]; then echo "${o[3]} ${o[2]} ${o[1]} ${o[0]}"; else echo "${o[@]}"; fi
}
cmd() { # metric guest tier arm file
  local c=none
  [ "$3" = compiled ] && c=$(cachedir $4)
  case $1 in
    split|steady) erlrun $4 -run requestbench main $1 $2 $3 off $c $5;;
    sat)          erlrun $4 -run attrbench main sat $2 compiled off $c $5;;
    density)      erlrun $4 -run densitybench main density $2 $5;;
    restore)      erlrun $4 -run restorebench main all 200 20 $5;;
    real)         erlrun $4 -run realbench main qjs > $5 2>&1;;
  esac
}
cell() { # round metric guest tier
  local r=$1 m=$2 g=$3 tier=$4 a=0 le dir=$OUT/raw/r$1 t
  mkdir -p $dir
  while [ $a -lt $MAX_ATTEMPTS ]; do
    a=$((a+1))
    wait_load >> $OUT/log/wait.log
    for t in $(order $r); do
      local f=$dir/${m}.${g}.${tier}.$t.terms ls t0
      rm -f $f; ls=$(load1); t0=$(date +%s)
      echo "== r$r $m $g $tier $t attempt $a $(uptime)" >> $OUT/log/r$r.log
      cmd $m $g $tier $t $f >> $OUT/log/r$r.log 2>&1
      le=$(load1)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" $r $m $g $tier $t $a $(( $(date +%s) - t0 )) $ls $le >> $LOADS
    done
    # A saturated cell pushes the load up itself and is not redone.
    if [ $m != sat ] && over $le; then
      mkdir -p $OUT/redone/r$r.$m.$g.$tier.$a
      for t in ${ARMS[@]}; do mv $dir/${m}.${g}.${tier}.$t.terms $OUT/redone/r$r.$m.$g.$tier.$a/; done
      echo "redo r$r $m $g $tier: end load $le"
    else
      echo "r$r $m $g $tier ok (attempt $a, end load $le) $(date +%H:%M)"; return 0
    fi
  done
  echo "r$r $m $g $tier VOID" | tee -a $OUT/void.txt
}
for r in $ROUNDS; do
  if [ -n "$SAT" ]; then
    # Reported, not gated: saturated throughput on a pool of 10.
    for g in $GUESTS; do cell $r sat $g compiled; done
  else
    for g in $GUESTS; do cell $r split $g compiled; done
    for g in $GUESTS; do cell $r steady $g compiled; done
    for g in $GUESTS; do cell $r steady $g interp; done
    for g in $GUESTS; do cell $r density $g -; done
    cell $r restore all -
    cell $r real qjs -
  fi
  echo "round $r done $(date)"
done
echo ROUNDS_DONE
