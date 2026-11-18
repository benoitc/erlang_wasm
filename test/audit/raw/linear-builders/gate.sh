#!/bin/sh
# Five pairs of launches in alternating order, one fresh emulator per launch.
# A and B are ebin roots (a build's _build/default/lib); OUT holds bench.beam.
# The null run passes the same root as both.
set -eu
cd "$(dirname "$0")/../../../.."
: "${A:?set A}" "${B:?set B}" "${OUT:?set OUT}"
for r in 1 2 3 4 5; do
  if [ $((r % 2)) -eq 1 ]; then order="a b"; else order="b a"; fi
  echo "round $r load $(uptime | sed 's/.*averages: //')"
  for arm in $order; do
    if [ $arm = a ]; then R=$A; else R=$B; fi
    erl -noshell -pa $R/*/ebin -pa $OUT -eval 'bench:run(), halt().' \
      | sed "s/^/$arm /"
  done
done
