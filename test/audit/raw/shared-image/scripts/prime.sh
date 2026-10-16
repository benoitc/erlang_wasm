#!/bin/bash
# Once per arm, before anything timed: the images each harness files in the
# tree, and the arm's code cache. Nothing here is a sample.
source $(dirname $0)/lib.sh
mkdir -p $OUT/prime
for t in "$@"; do
  O=$OUT/prime/$t.txt; d=$(tree $t); c=$(cachedir $t)
  rm -rf $d/_build/imagecache $d/_build/requestbench $d/_build/densitybench
  mkdir -p $c
  echo "# start $(uptime)" > $O
  erlrun $t -run restorebench main all 3 1 none >> $O 2>&1
  for g in py_entry qjs lua py; do
    ARB_SMOKE=1 erlrun $t -run requestbench main steady $g interp off none none >> $O 2>&1
    ARB_SMOKE=1 erlrun $t -run requestbench main steady $g compiled off $c none >> $O 2>&1
    erlrun $t -run densitybench main poolstart $g 2 none >> $O 2>&1
  done
  ARB_SMOKE=1 erlrun $t -run attrbench main steady py_entry compiled off $c none >> $O 2>&1
  echo "PRIME_DONE $(uptime)" >> $O
  echo "primed $t"
done
