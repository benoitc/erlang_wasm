#!/bin/bash
# plaindiag in main, prev (e5826ab), cand (61e4ef1), null; 3 rounds, rotating order.
O=/Users/benoitc/Projects/erlang_wasm/test/audit/raw/pool-image/rerun2/plain-diag
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
for r in 1 2 3; do
  case $r in 1) o="main prev cand null";; 2) o="null cand prev main";; 3) o="cand main null prev";; esac
  for a in $o; do
    until awk -v l="$(load1)" 'BEGIN{exit !(l < 8)}'; do sleep 20; done
    (cd /Users/benoitc/Projects/ewbench-$a && erlc -o $O/ebin-$a -pa _build/default/lib/wasm/ebin $O/plaindiag.erl 2>/dev/null; \
     erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa bench/paths -pa $O/ebin-$a -run plaindiag main 3000 $O/$a-r$r.terms > /dev/null 2>&1)
    echo "r$r $a $(load1)" >> $O/loads.log
  done
done
echo DIAGDONE >> $O/loads.log
