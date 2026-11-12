#!/bin/bash
# The call-path gate for the application generation check: parent against
# candidate, five pairs, odd pairs parent first, each run in a fresh VM started
# at a one-minute load below 8.
PARENT=$1; CAND=$2; OUT=$3
waitload() { until awk -v l="$(sysctl -n vm.loadavg | awk '{print $2}')" 'BEGIN{exit !(l < 8)}'; do sleep 20; done; }
run() { (cd "$1" && shift && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa bench/paths "$@" 2>&1 | grep -vE "^=|^ *(application|exited|type):" | tr '\n' ' '); }
for r in 1 2 3 4 5; do
  if [ $((r % 2)) = 1 ]; then order="parent cand"; else order="cand parent"; fi
  for arm in callk qjs; do
    for t in $order; do
      if [ $t = parent ]; then d=$PARENT; else d=$CAND; fi
      waitload
      l=$(sysctl -n vm.loadavg | awk '{print $2}')
      if [ $arm = callk ]; then res=$(run $d -run callk main go); else res=$(run $d -run realbench main qjs); fi
      echo "r=$r $t $arm load=$l $res" >> "$OUT"
    done
  done
done
