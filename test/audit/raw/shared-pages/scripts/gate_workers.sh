source $(dirname $0)/lib.sh
round_start() { wait_load | tee -a $1/uptime.txt; echo "round $2 $(uptime)" >> $1/uptime.txt; }
O=$RAW/workers; mkdir -p $O
for r in 1 2 3 4 5; do round_start $O $r
  for g in py qjs lua; do for a in off on; do
    for t in $(order $r); do echo "== r$r $t $g $a" >> $O/$t.txt; erlrun $t -run densitybench main workers $g 50 $a $O/$t.terms >> $O/$t.txt 2>&1; done
  done; done
done
echo workers done
O=$RAW/workerstart; mkdir -p $O
for r in 1 2 3 4 5; do round_start $O $r
  for t in $(order $r); do echo "== r$r $t" >> $O/$t.txt; erlrun $t -run capturebench main worker py,py_entry,qjs,lua 1 $O/$t.terms >> $O/$t.txt 2>&1; done
done
echo GATE_WORKERS_DONE
