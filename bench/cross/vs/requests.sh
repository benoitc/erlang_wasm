#!/bin/bash
# The CPython request gate: requestbench steady py compiled, baseline against
# candidate, on the trees run.sh built in OUTDIR/trees.
#
# Usage: requests.sh OUTDIR [ROUNDS]
#
# Each tree gets its own code cache, filled by one unrecorded run. Then ROUNDS
# rounds, the order swapped every round, one fresh VM per tree per round, with
# run.sh's load rules: a run starts below load 8, is redone up to three times
# when it ends at 8 or more, and a round still overloaded is set aside and run
# again, up to three times. requests.escript reads the results.
set -euo pipefail
OUT=$(cd "$1" && pwd); ROUNDS=${2:-5}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TREES=$OUT/trees
[ -f "$TREES/baseline/MANIFEST" ] && [ -f "$TREES/candidate/MANIFEST" ] \
  || { echo "run run.sh first: no trees in $TREES"; exit 1; }
REQ=$OUT/requests; HARNESS=$REQ/harness
mkdir -p "$REQ" "$HARNESS"
cd "$ROOT"
# The guests are not in git: copy them into both trees.
for t in baseline candidate; do
  mkdir -p "$TREES/$t/test/fixtures/lang"
  cp test/fixtures/lang/*.wasm "$TREES/$t/test/fixtures/lang/"
  cp -R test/fixtures/lang/py_reactor_lib "$TREES/$t/test/fixtures/lang/"
done
erlc -o "$HARNESS" -pa "$TREES/candidate/_build/default/lib/wasm/ebin" \
    bench/paths/reactorlib.erl bench/paths/requestbench.erl

load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
# VS_LOAD_LIMIT lowers the limit only to show that an overloaded round is
# set aside and, three times over, fails the run.
LIMIT=${VS_LOAD_LIMIT:-8}
below8() { awk -v l="$1" -v m="$LIMIT" 'BEGIN{exit !(l < m)}'; }
startable() { awk -v l="$1" 'BEGIN{exit !(l < 8)}'; }
wait_quiet() { until startable "$(load1)"; do sleep 20; done; }

# req TREE NAME: one VM, from inside the tree, with the tree's own cache.
req() {
  local t=$1 name=$2
  (cd "$TREES/$t" && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin \
      -pa "$HARNESS" -run requestbench main steady py compiled off \
      "$REQ/cache-$t" "$REQ/$name.terms") > "$REQ/$name.out" 2>&1
}

for t in baseline candidate; do
  mkdir -p "$REQ/cache-$t"; chmod 700 "$REQ/cache-$t"
  wait_quiet; req "$t" "warm-$t"
  grep -q "verdict => ok" "$REQ/warm-$t.out" || { echo "warm-up of $t failed"; exit 1; }
done

for r in $(seq 1 "$ROUNDS"); do
  if [ $((r % 2)) = 1 ]; then order="baseline candidate"; else order="candidate baseline"; fi
  for rattempt in 1 2 3; do
    ok=1
    for t in $order; do
      name="$t-r$r"; kept=0
      for a in 1 2 3; do
        wait_quiet; l0=$(load1)
        rm -f "$REQ/$name.terms"
        req "$t" "$name"
        grep -q "verdict => ok" "$REQ/$name.out" || { echo "$name failed; see $REQ/$name.out"; exit 1; }
        l1=$(load1)
        echo "$name attempt$a load $l0 -> $l1" >> "$REQ/loads.log"
        if below8 "$l1"; then kept=1; break; fi
      done
      if [ $kept = 0 ]; then mv "$REQ/$name.terms" "$REQ/$name.overloaded"; ok=0; break; fi
    done
    if [ $ok = 1 ]; then break; fi
    mkdir -p "$REQ/rejected/r$r-attempt$rattempt"
    mv "$REQ"/*-r"$r".* "$REQ/rejected/r$r-attempt$rattempt/" 2>/dev/null || true
    if [ "$rattempt" = 3 ]; then echo "round $r overloaded three times"; exit 1; fi
  done
done
echo DONE >> "$REQ/loads.log"
