# Source it. Arms: main (14d3d81), null (main's tree and cache under a second
# name), cand (branch outline-miss, two entries), one (cand with one entry,
# scratch only).
R=/Users/benoitc/Projects/erlang_wasm-om-results
P=/Users/benoitc/Projects
OUT=${OUT:-$R/results}
LOAD_MAX=8
tree() { case $1 in null) echo $P/erlang_wasm-om-main;; *) echo $P/erlang_wasm-om-$1;; esac; }
cachedir() { case $1 in null) echo $HOME/.cache/wasm-om/main;; *) echo $HOME/.cache/wasm-om/$1;; esac; }
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
over() { [ $(echo "$1 >= $LOAD_MAX" | bc) -eq 1 ]; }
wait_load() {
  local i=0
  while over $(load1); do sleep 20; i=$((i+1)); done
  echo "# wait_load polls=$i load1=$(load1) $(uptime)"
}
erlrun() {
  local t=$1; shift
  (cd $(tree $t) && ERL_LIBS=_build/default/lib erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/om "$@")
}
