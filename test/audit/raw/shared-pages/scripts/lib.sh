B=/Users/benoitc/Projects/erlang_wasm-baseline-a2bda33
C=/Users/benoitc/Projects/erlang_wasm-shared-pages
RAW=$C/test/audit/raw/shared-pages
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
wait_load() {
  local i=0
  while [ $(echo "$(load1) >= 8" | bc) -eq 1 ] && [ $i -lt 60 ]; do sleep 30; i=$((i+1)); done
  echo "# wait_load polls=$i load1=$(load1) $(uptime)"
}
tree() { if [ "$1" = base ]; then echo $B; else echo $C; fi; }
cachedir() { if [ "$1" = base ]; then echo $HOME/.cache/wasm-gates/baseline; else echo $HOME/.cache/wasm-gates/candidate; fi; }
# order for round r: odd rounds base first, even rounds cand first
order() { if [ $(($1 % 2)) -eq 1 ]; then echo "base cand"; else echo "cand base"; fi; }
erlrun() { local t=$1; shift; (cd $(tree $t) && erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths "$@"); }
