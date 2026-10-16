# Source it. Arms: main (bd8b7b6), null (main's tree under a second name, its
# own code cache), cand (branch shared-image).
R=/Users/benoitc/Projects/erlang_wasm-si-results
P=/Users/benoitc/Projects
OUT=${OUT:-$R/results}
LOAD_MAX=8
tree() { case $1 in null) echo $P/erlang_wasm-si-main;; *) echo $P/erlang_wasm-si-$1;; esac; }
cachedir() { echo $HOME/.cache/wasm-si/$1; }
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
over() { [ $(echo "$1 >= $LOAD_MAX" | bc) -eq 1 ]; }
wait_load() {
  local i=0
  while over $(load1); do sleep 20; i=$((i+1)); done
  echo "# wait_load polls=$i load1=$(load1) $(uptime)"
}
erlrun() {
  local t=$1; shift
  (cd $(tree $t) && ERL_LIBS=_build/default/lib erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/si "$@")
}
