# Shared by the fault-copy scripts. Source it; never run it.
# Adapted from ../shared-pages/arbitration/lib.sh: three arms, main (9e243cb),
# c1 (the unrolled copy only) and c2 (both changes).
FC=/Users/benoitc/Projects/erlang_wasm/test/audit/raw/fault-copy
P=/Users/benoitc/Projects
OUT=${OUT:-$FC/results}
ARMS="main c1 c2"
LOAD_MAX=8

tree() { echo $P/erlang_wasm-fc-$1; }
cachedir() { echo $HOME/.cache/wasm-fc/$1; }

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
  (cd $(tree $t) && ERL_LIBS=_build/default/lib erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin \
     -pa bench/arb "$@")
}

# All six orderings of three arms: each arm precedes each other arm in three
# rounds and follows it in three.
order() {
  case $(( ($1 - 1) % 6 )) in
    0) echo "main c1 c2";; 1) echo "c1 c2 main";; 2) echo "c2 main c1";;
    3) echo "main c2 c1";; 4) echo "c1 main c2";; 5) echo "c2 c1 main";;
  esac
}
