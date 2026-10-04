cd /Users/benoitc/Projects/erlang_wasm-prof-harness
until grep -q EXP1_DONE out/exp1_uptime.txt 2>/dev/null; do sleep 20; done
bash exp2.sh; bash exp3.sh
source lib.sh; wait_load >> $O/inst_low_uptime.txt; bash inst.sh low; bash inst.sh low2
echo ALL_DONE > out/all_done
