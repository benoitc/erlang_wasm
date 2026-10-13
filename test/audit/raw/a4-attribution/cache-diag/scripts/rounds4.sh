#!/bin/bash
# Call phase: requestbench split, compiled, primed caches. A cell is one guest
# on all six arms in fresh VMs; round r rotates the arms by r and reverses on
# even rounds. Start gated at load1 < 8; redone (files kept) when load1 at the
# end of its last arm is >= 8.
source $(dirname $0)/lib.sh
ROUNDS=${ROUNDS:-"1 2 3 4 5"}
GUESTS=${GUESTS:-"py_entry qjs lua py"}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-5}
ARMS=(base v0 null v4 v5 v6)
mkdir -p $OUT/raw $OUT/log $OUT/redone
LOADS=$OUT/loads.tsv
[ -f $LOADS ] || printf "round\tguest\tarm\tattempt\tsecs\tload_start\tload_end\n" > $LOADS
order() {
  local r=$1 o=() k
  for k in 0 1 2 3 4 5; do o+=(${ARMS[$(( (k + r) % 6 ))]}); done
  if [ $((r % 2)) -eq 0 ]; then echo "${o[5]} ${o[4]} ${o[3]} ${o[2]} ${o[1]} ${o[0]}"; else echo "${o[@]}"; fi
}
cell() {
  local r=$1 g=$2 a=0 le dir=$OUT/raw/r$1
  mkdir -p $dir
  while [ $a -lt $MAX_ATTEMPTS ]; do
    a=$((a+1))
    wait_load >> $OUT/log/wait.log
    for t in $(order $r); do
      local f=$dir/split_${g}_$t.terms ls t0
      rm -f $f; ls=$(load1); t0=$(date +%s)
      echo "== r$r $g $t attempt $a $(uptime)" >> $OUT/log/r$r.log
      erlrun $t -run requestbench main split $g compiled off $(cachedir $t) $f >> $OUT/log/r$r.log 2>&1
      le=$(load1)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" $r $g $t $a $(( $(date +%s) - t0 )) $ls $le >> $LOADS
    done
    if over $le; then
      mkdir -p $OUT/redone/r$r.$g.$a; mv $dir/split_${g}_*.terms $OUT/redone/r$r.$g.$a/
      echo "redo r$r $g: end load $le"
    else
      echo "r$r $g ok (attempt $a, end load $le) $(date +%H:%M)"; return 0
    fi
  done
  echo "r$r $g VOID" | tee -a $OUT/void.txt
}
for r in $ROUNDS; do for g in $GUESTS; do cell $r $g; done; echo "round $r done $(date)"; done
echo ROUNDS_DONE
