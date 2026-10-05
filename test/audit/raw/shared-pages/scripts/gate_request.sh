source $(dirname $0)/lib.sh
O=$RAW/request; mkdir -p $O
populate() { local t=$1
  for g in py qjs lua; do
    echo "== populate $t $g interp" >> $O/populate_$t.txt
    erlrun $t -run requestbench main steady $g interp off none none >> $O/populate_$t.txt 2>&1
    echo "== populate $t $g compiled" >> $O/populate_$t.txt
    erlrun $t -run requestbench main steady $g compiled off $(cachedir $t) none >> $O/populate_$t.txt 2>&1
  done; }
populate base & populate cand & wait
echo populated
for r in 1 2 3 4 5; do
  wait_load | tee -a $O/uptime.txt; echo "round $r $(uptime)" >> $O/uptime.txt
  for g in py qjs lua; do for tier in interp compiled; do for a in off on; do
    for i in 1 2 3 4 5; do
      for t in $(order $((r+i))); do
        if [ $tier = compiled ]; then c=$(cachedir $t); else c=none; fi
        echo "== r$r $t first $g $tier $a $i" >> $O/$t.txt
        erlrun $t -run requestbench main first $g $tier $a $c $O/first_$t.terms >> $O/$t.txt 2>&1
      done
    done
    for t in $(order $r); do
      if [ $tier = compiled ]; then c=$(cachedir $t); else c=none; fi
      echo "== r$r $t steady $g $tier $a" >> $O/$t.txt
      erlrun $t -run requestbench main steady $g $tier $a $c $O/steady_$t.terms >> $O/$t.txt 2>&1
    done
  done; done; done
  echo "round $r done"
done
echo GATE_REQUEST_DONE
