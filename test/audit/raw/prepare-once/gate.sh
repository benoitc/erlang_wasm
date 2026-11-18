#!/bin/sh
# Cold wasm_component:prepare/1 and instantiating from a prepared component,
# main against the branch, five rounds in
# alternating order. $OUT holds bench.beam and main_ebin/: the branch's ebin
# with main's wasm_component.erl and wasm_component_link.erl
# compiled over it (erlc -I include -o $OUT/main_ebin ...).
set -eu
cd "$(dirname "$0")/../../../.."
: "${OUT:?set OUT}"
for r in 1 2 3 4 5; do
  if [ $((r % 2)) -eq 1 ]; then order="main branch"; else order="branch main"; fi
  echo "round $r load $(uptime | sed 's/.*averages: //')"
  for arm in $order; do
    if [ $arm = main ]; then P="-pa $OUT/main_ebin"; else P=""; fi
    erl -noshell -pa _build/default/lib/*/ebin $P -pa $OUT -eval 'bench:run(), halt().' | sed "s/^/$arm /"
  done
done
