#!/bin/sh
# reqbench on the CPython reactor, 14 workers, 64 callers, 10 s, five pairs
# of launches in alternating order. A and B are ebin roots (a build's
# _build/default/lib); BEAMS holds reqbench.beam. The null run passes the
# same root as both.
set -eu
cd "$(dirname "$0")/../../../.."
: "${A:?set A}" "${B:?set B}" "${BEAMS:?set BEAMS}"
for r in 1 2 3 4 5; do
  if [ $((r % 2)) -eq 1 ]; then order="a b"; else order="b a"; fi
  echo "round $r load $(uptime | sed 's/.*averages: //')"
  for arm in $order; do
    if [ $arm = a ]; then R=$A; else R=$B; fi
    erl -noshell -pa $R/*/ebin -pa $BEAMS -run reqbench main py 14 64 10 "" \
      | grep -E "req/s|file_server_2|failed" | sed "s/^/$arm /"
  done
done
