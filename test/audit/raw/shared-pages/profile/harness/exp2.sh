source /Users/benoitc/Projects/erlang_wasm-prof-harness/lib.sh
for r in 1 2 3; do
  if [ $((r % 2)) -eq 1 ]; then ORD="v0 v1 v4"; else ORD="v4 v1 v0"; fi
  wait_load >> $O/exp2_uptime.txt
  for v in $ORD; do
    echo "== r$r $v $(uptime)" >> $O/exp2_$v.txt
    erlrun $v -run loadprof main all 20 $O/load_$v.terms >> $O/exp2_$v.txt 2>&1
  done
done
echo EXP2_DONE >> $O/exp2_uptime.txt
