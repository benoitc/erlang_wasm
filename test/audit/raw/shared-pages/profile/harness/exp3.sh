source /Users/benoitc/Projects/erlang_wasm-prof-harness/lib.sh
for r in 1 2 3; do
  if [ $((r % 2)) -eq 1 ]; then ORD="v0 v1"; else ORD="v1 v0"; fi
  wait_load >> $O/exp3_uptime.txt
  for g in py qjs lua; do for v in $ORD; do
    echo "== r$r $v $g $(uptime)" >> $O/exp3_$v.txt
    erlrun $v -run densitybench main density $g $O/density_$v.terms >> $O/exp3_$v.txt 2>&1
  done; done
done
echo EXP3_DONE >> $O/exp3_uptime.txt
