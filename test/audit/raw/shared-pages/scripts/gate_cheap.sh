source $(dirname $0)/lib.sh
round_start() { wait_load | tee -a $1/uptime.txt; echo "round $2 $(uptime)" >> $1/uptime.txt; }

# gate 5: memory kernels
O=$RAW/kernels; mkdir -p $O
for r in 1 2 3 4 5; do round_start $O $r
  for k in store sieve; do for m in plain paged; do for tier in interp compiled; do
    for t in $(order $r); do echo -n "r$r $t " >> $O/$t.txt; erlrun $t -run pagedbench main $k $m $tier >> $O/$t.txt 2>&1; done
  done; done; done
done
echo kernels done

# gate 4: realbench qjs
O=$RAW/realbench; mkdir -p $O
for r in 1 2 3 4 5; do round_start $O $r
  for t in $(order $r); do echo "== r$r $t $(uptime)" >> $O/$t.txt; erlrun $t -run realbench main qjs >> $O/$t.txt 2>&1; done
done
echo realbench done

# gate 6: fresh instantiate
O=$RAW/instantiate; mkdir -p $O
for r in 1 2 3 4 5; do round_start $O $r
  for a in const gget uncached; do
    for t in $(order $r); do echo -n "r$r $t " >> $O/$t.txt; erlrun $t -run instbench main $a >> $O/$t.txt 2>&1; done
  done
done
echo instantiate done

# gate 7: sharing
O=$RAW/sharing; mkdir -p $O
for r in 1 2 3 4 5; do round_start $O $r
  for g in py qjs lua; do
    for t in $(order $r); do echo "== r$r $t $g" >> $O/$t.txt; erlrun $t -run densitybench main sharing $g 50 $O/$t.terms >> $O/$t.txt 2>&1; done
  done
done
echo sharing done

# gate 9: density
O=$RAW/density; mkdir -p $O
for r in 1 2 3 4 5; do round_start $O $r
  for g in py qjs lua; do
    for t in $(order $r); do echo "== r$r $t $g" >> $O/$t.txt; erlrun $t -run densitybench main density $g $O/$t.terms >> $O/$t.txt 2>&1; done
  done
done
echo density done

# gate 10: snapshot
O=$RAW/snapshot; mkdir -p $O
for r in 1 2 3 4 5; do round_start $O $r
  for t in $(order $r); do echo "== r$r $t" >> $O/$t.txt; erlrun $t -run capturebench main snapshot py,py_entry 2 2 $O/$t.terms >> $O/$t.txt 2>&1; done
done
echo GATE_CHEAP_DONE
