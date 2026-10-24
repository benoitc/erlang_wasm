#!/bin/bash
# erlang_wasm against erlang-wasmtime: five rounds, one fresh VM per runtime
# per round, the order swapped every round. A run starts only below a
# one-minute load of 8 and is redone (up to three attempts) when it ends at 8
# or more. Usage: run.sh QJS_WASM OUTDIR [WASMTIME_EBIN]
set -e
QJS=$1; OUT=$2
WT=${3:-$HOME/Projects/erlang-wasmtime/_build/default/lib/erlang_wasmtime/ebin}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT"
for f in mem fib bulk nop; do
  wasm-tools parse bench/cross/vs/$f.wat -o bench/cross/vs/$f.wasm
done
erlc -o bench/cross/vs bench/cross/vs/vs.erl
mkdir -p "$OUT"
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
below8() { awk -v l="$(load1)" 'BEGIN{exit !(l < 8)}'; }
for r in 1 2 3 4 5; do
  if [ $((r % 2)) = 1 ]; then arms="erlang_wasm wasmtime"; else arms="wasmtime erlang_wasm"; fi
  for a in $arms; do
    for attempt in 1 2 3; do
      until below8; do sleep 20; done
      l0=$(load1)
      erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa "$WT" \
          -pa bench/cross/vs -run vs main $a "$QJS" "$OUT/$a-r$r.terms" \
          > "$OUT/$a-r$r.out" 2>&1
      l1=$(load1)
      echo "r$r $a attempt$attempt load $l0 -> $l1" >> "$OUT/loads.log"
      awk -v l="$l1" 'BEGIN{exit !(l < 8)}' && break
    done
  done
done
echo DONE >> "$OUT/loads.log"
