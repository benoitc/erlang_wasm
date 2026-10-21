#!/bin/bash
# restorebench plain, 2000 loads a run, in main, prev (e5826ab) and cand (61e4ef1);
# 3 rounds, rotating order, each run started below a load of 8.
O=/Users/benoitc/Projects/erlang_wasm/test/audit/raw/pool-image/rerun2/plain-load-prev
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
for r in 1 2 3; do
  case $r in 1) o="main prev cand";; 2) o="cand prev main";; 3) o="prev main cand";; esac
  for a in $o; do
    until awk -v l="$(load1)" 'BEGIN{exit !(l < 8)}'; do sleep 20; done
    l0=$(load1)
    (cd /Users/benoitc/Projects/ewbench-$a && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa bench/paths -run restorebench main plain 200 2000 $O/$a-r$r.terms > $O/$a-r$r.out 2>&1)
    echo "r$r $a load $l0 -> $(load1)" >> $O/loads.log
  done
done
echo PREVDONE >> $O/loads.log
