H=/Users/benoitc/Projects/erlang_wasm-prof-harness
O=$H/out
P=/Users/benoitc/Projects
tree() { case $1 in v0) echo $P/erlang_wasm-baseline-a2bda33;; v0b) echo $P/erlang_wasm-prof-v0b;; v1) echo $P/erlang_wasm-shared-pages;; v2) echo $P/erlang_wasm-prof-v2;; v3) echo $P/erlang_wasm-prof-v3;; inst) echo $P/erlang_wasm-prof-inst;; v4) echo $P/erlang_wasm-prof-v4;; esac; }
cache() { case $1 in v4) echo $HOME/.cache/wasm-prof/v1;; *) echo $HOME/.cache/wasm-prof/$1;; esac; }
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
wait_load() {
  local i=0
  while [ $(echo "$(load1) >= 8" | bc) -eq 1 ] && [ $i -lt 240 ]; do sleep 30; i=$((i+1)); done
  echo "# wait_load polls=$i load1=$(load1) $(uptime)"
}
erlrun() { local t=$1; shift; (cd $(tree $t) && erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/paths -pa $H "$@"); }
