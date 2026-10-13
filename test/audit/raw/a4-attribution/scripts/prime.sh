#!/bin/bash
# Fill each tree's code cache and image directory. Not a sample.
source $(dirname $0)/lib.sh
mkdir -p $OUT/prime
prime() {
  local t=$1 O=$OUT/prime/$1.txt c=$(cachedir $1)
  mkdir -p $c
  echo "# start $(uptime)" > $O
  for g in py_entry py qjs lua; do
    ARB_SMOKE=1 erlrun $t -run requestbench main steady $g compiled off $c none >> $O 2>&1
  done
  echo "PRIME_DONE $(uptime)" >> $O
}
for t in ${ARMS:-base main inst}; do prime $t & done; wait
grep -c "verdict => ok" $OUT/prime/*.txt
