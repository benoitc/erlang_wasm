# Source it. Arms: base (a2bda33), v0 (main), v1 one entry, v2 no cache,
# v3 cache not carried; null = v0's tree and cache under a second name.
R=/Users/benoitc/Projects/erlang_wasm-cache-diag
P=/Users/benoitc/Projects
OUT=${OUT:-$R/results}
LOAD_MAX=8
tree() { case $1 in null) echo $P/erlang_wasm-cdiag-v0;; *) echo $P/erlang_wasm-cdiag-$1;; esac; }
cachedir() { case $1 in null) echo $HOME/.cache/wasm-cdiag/v0;; *) echo $HOME/.cache/wasm-cdiag/$1;; esac; }
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
over() { [ $(echo "$1 >= $LOAD_MAX" | bc) -eq 1 ]; }
wait_load() {
  local i=0
  while over $(load1); do sleep 20; i=$((i+1)); done
  echo "# wait_load polls=$i load1=$(load1) $(uptime)"
}
erlrun() {
  local t=$1; shift
  (cd $(tree $t) && ERL_LIBS=_build/default/lib erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/attr "$@")
}
