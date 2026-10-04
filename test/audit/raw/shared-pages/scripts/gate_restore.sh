source $(dirname $0)/lib.sh
OUT=$RAW/restore; mkdir -p $OUT
for r in 1 2 3 4 5; do
  wait_load | tee -a $OUT/uptime.txt
  echo "round $r $(uptime)" >> $OUT/uptime.txt
  for t in $(order $r); do
    erlrun $t -run restorebench main all 200 20 $OUT/$t.terms > $OUT/$t.r$r.txt 2>&1
  done
done
echo GATE_RESTORE_DONE
