#!/bin/bash
# Once per arm, before anything timed: the images each harness files in the
# tree (requestbench, restorebench, densitybench). Nothing here is a sample.
# The code caches are filled by cold.sh, whose runs are the cold-compile gate.
source $(dirname $0)/lib.sh
mkdir -p $OUT/prime
for t in "$@"; do
  O=$OUT/prime/$t.txt; d=$(tree $t)
  rm -rf $d/_build/imagecache $d/_build/requestbench $d/_build/densitybench
  echo "# start $(uptime)" > $O
  erlrun $t -run restorebench main all 3 1 none >> $O 2>&1
  for g in py_entry qjs lua py; do
    ARB_SMOKE=1 erlrun $t -run requestbench main steady $g interp off none none >> $O 2>&1
    erlrun $t -run densitybench main density $g none >> $O 2>&1
  done
  erlrun $t -run realbench main qjs >> $O 2>&1
  echo "PRIME_DONE $(uptime)" >> $O
  echo "primed $t"
done
