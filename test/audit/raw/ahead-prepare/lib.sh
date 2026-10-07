# Shared by the ahead-prepare scripts. Source it; never run it.
# Adapted from ../fault-copy/lib.sh: two arms, main (4cba5fe) and cand.
AP=/Users/benoitc/Projects/erlang_wasm/test/audit/raw/ahead-prepare
P=/Users/benoitc/Projects
OUT=${OUT:-$AP/results}
ARMS=${ARMS:-"main cand"}
LOAD_MAX=8

tree() { echo $P/erlang_wasm-ap-$1; }
cachedir() { echo $HOME/.cache/wasm-ap/$1; }

load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
over() { [ $(echo "$1 >= $LOAD_MAX" | bc) -eq 1 ]; }
wait_load() {
  local i=0
  while over $(load1); do sleep 30; i=$((i+1)); done
  echo "# wait_load polls=$i load1=$(load1) $(uptime)"
}

# One arm per fresh VM, from inside its own tree, +S 10:10.
erlrun() {
  local t=$1; shift
  (cd $(tree $t) && ERL_LIBS=_build/default/lib erl -noshell +S 10:10 \
     -pa _build/default/lib/wasm/ebin -pa bench/arb "$@")
}

# Five pairs, alternating which arm goes first.
order() {
  case $(( $1 % 2 )) in
    1) echo "main cand";; 0) echo "cand main";;
  esac
}
