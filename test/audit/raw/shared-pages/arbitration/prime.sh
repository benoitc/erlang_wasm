#!/bin/bash
# Once, before round 1: empty each arm's code cache and image caches, then
# fill them. Arms prime in parallel; nothing here is a sample.
source $(dirname $0)/lib.sh
unset ARB_SMOKE
mkdir -p $OUT/prime
prime() {
  local t=$1 O=$OUT/prime/$1.txt c=$(cachedir $1) d=$(tree $1)
  rm -rf $c && mkdir -p $c
  rm -rf $d/_build/imagecache $d/_build/requestbench $d/_build/densitybench
  echo "# start $(uptime)" > $O
  erlrun $t -run restorebench main all 3 1 none >> $O 2>&1
  for g in $GUESTS; do
    erlrun $t -run requestbench main steady $g interp off none none >> $O 2>&1
    erlrun $t -run requestbench main steady $g compiled off $c none >> $O 2>&1
  done
  echo "# cache $(find $c -type f | wc -l) files $(du -sh $c | cut -f1)" >> $O
  echo "PRIME_DONE $(uptime)" >> $O
}
for t in ${PRIME_ARMS:-$ARMS}; do prime $t & done; wait
missing=$(for t in ${PRIME_ARMS:-$ARMS}; do grep -q PRIME_DONE $OUT/prime/$t.txt || echo $t; done)
[ -z "$missing" ] && echo PRIMED || echo "PRIME INCOMPLETE: $missing"
bad=$(grep -l "failed:\|VOID" $OUT/prime/*.txt)
[ -n "$bad" ] && echo "PRIME HAD FAILURES: $bad" || true
