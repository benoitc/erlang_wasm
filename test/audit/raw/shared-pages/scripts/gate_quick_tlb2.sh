source $(dirname $0)/lib.sh
# 20 min cap (40 polls x 30 s)
wait_load() {
  local i=0
  while [ $(echo "$(load1) >= 8" | bc) -eq 1 ] && [ $i -lt 40 ]; do sleep 30; i=$((i+1)); done
  echo "# wait_load polls=$i load1=$(load1) $(uptime)"
}
O=$RAW/quick-tlb2; mkdir -p $O
T0=$(date +%s)
echo "start $(date) $(uptime)" > $O/uptime.txt
# warm-up: repopulate candidate code cache (baseline warmed too), images
warm() { local t=$1
  for g in py qjs lua; do
    echo "== warm $t $g compiled" >> $O/warm_$t.txt
    erlrun $t -run requestbench main steady $g compiled off $(cachedir $t) none >> $O/warm_$t.txt 2>&1
  done
  erlrun $t -run restorebench main all 2 2 none >> $O/warm_$t.txt 2>&1; }
warm cand & warm base & wait
echo "warm done $(( $(date +%s) - T0 ))s $(uptime)" >> $O/uptime.txt
for r in 1 2 3; do
  wait_load | tee -a $O/uptime.txt; echo "round $r $(date +%T) $(uptime)" >> $O/uptime.txt
  for g in py qjs lua; do for tier in interp compiled; do
    for t in $(order $r); do
      if [ $tier = compiled ]; then c=$(cachedir $t); else c=none; fi
      echo "== r$r $t steady $g $tier off" >> $O/request_$t.txt
      erlrun $t -run requestbench main steady $g $tier off $c $O/steady_$t.terms >> $O/request_$t.txt 2>&1
    done
  done; done
  for t in $(order $r); do
    erlrun $t -run restorebench main all 20 20 $O/restore_$t.terms > $O/restore_$t.r$r.txt 2>&1
  done
  for k in store sieve; do for m in plain paged; do
    for t in $(order $r); do echo -n "r$r $t " >> $O/kernels_$t.txt; erlrun $t -run pagedbench main $k $m compiled >> $O/kernels_$t.txt 2>&1; done
  done; done
  for t in $(order $r); do echo "== r$r $t $(uptime)" >> $O/realbench_$t.txt; erlrun $t -run realbench main qjs >> $O/realbench_$t.txt 2>&1; done
  echo "round $r end $(date +%T) $(uptime)" >> $O/uptime.txt
done
echo "end $(date) wall=$(( $(date +%s) - T0 ))s $(uptime)" >> $O/uptime.txt
echo GATE_QUICK_DONE
