source /Users/benoitc/Projects/erlang_wasm-prof-harness/lib.sh
for r in 1 2 3; do
  if [ $((r % 2)) -eq 1 ]; then ORD="v0 v1 v2 v3"; else ORD="v3 v2 v1 v0"; fi
  for g in py qjs lua; do for tier in interp compiled; do
    wait_load >> $O/exp1_uptime.txt
    for v in $ORD; do
      if [ $tier = compiled ]; then c=$(cache $v); else c=none; fi
      echo "== r$r $v $g $tier $(uptime)" >> $O/exp1_$v.txt
      erlrun $v -run requestbench main steady $g $tier off $c $O/steady_$v.terms >> $O/exp1_$v.txt 2>&1
      erlrun $v -run profreq main $g $tier $c 100 $O/prof_$v.terms >> $O/exp1p_$v.txt 2>&1
    done
  done; done
  echo "round $r done $(uptime)" >> $O/exp1_uptime.txt
done
echo EXP1_DONE >> $O/exp1_uptime.txt
