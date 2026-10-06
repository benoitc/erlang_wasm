#!/bin/bash
# Once, before round 1: empty each arm's code and image caches, then fill them.
# Arms prime in parallel; nothing here is a sample.
source $(dirname $0)/lib.sh
mkdir -p $OUT/prime
prime() {
  local t=$1 O=$OUT/prime/$1.txt c=$(cachedir $1) d=$(tree $1)
  rm -rf $c && mkdir -p $c
  rm -rf $d/_build/imagecache $d/_build/requestbench $d/_build/densitybench
  echo "# start $(uptime)" > $O
  for g in ${GUESTS:-py_entry py qjs lua}; do
    erlrun $t -run requestbench main steady $g interp off none none >> $O 2>&1
    erlrun $t -run requestbench main steady $g compiled off $c none >> $O 2>&1
  done
  echo "# cache $(find $c -type f | wc -l) files $(du -sh $c | cut -f1)" >> $O
  echo "PRIME_DONE $(uptime)" >> $O
}
for t in $ARMS; do prime $t & done; wait
for t in $ARMS; do grep -q PRIME_DONE $OUT/prime/$t.txt || echo "PRIME INCOMPLETE $t"; done
grep -l "failed:\|VOID\|void" $OUT/prime/*.txt && echo "PRIME HAD FAILURES" || echo PRIMED
