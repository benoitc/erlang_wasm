# Shared by the attribution scripts. Source it; never run it.
# Arms: base (a2bda33, 0.8), main (origin/main a67a4b2), null (main again:
# the same tree and cache under a second name, for the null comparison).
R=/Users/benoitc/Projects/erlang_wasm-attr-results
P=/Users/benoitc/Projects
OUT=${OUT:-$R/results}
LOAD_MAX=8
tree() { case $1 in base) echo $P/erlang_wasm-attr-base;; main|null) echo $P/erlang_wasm-attr-main;; inst) echo $P/erlang_wasm-attr-inst;; esac; }
cachedir() { case $1 in null) echo $HOME/.cache/wasm-attr/main;; *) echo $HOME/.cache/wasm-attr/$1;; esac; }
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
over() { [ $(echo "$1 >= $LOAD_MAX" | bc) -eq 1 ]; }
wait_load() {
  local i=0
  while over $(load1); do sleep 30; i=$((i+1)); done
  echo "# wait_load polls=$i load1=$(load1) $(uptime)"
}
erlrun() {
  local t=$1; shift
  (cd $(tree $t) && ERL_LIBS=_build/default/lib erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin -pa bench/attr "$@")
}
# Three arms, all six orderings.
order() {
  case $(( ($1 - 1) % 6 )) in
    0) echo "base main null";; 1) echo "main null base";; 2) echo "null base main";;
    3) echo "base null main";; 4) echo "main base null";; 5) echo "null main base";;
  esac
}
