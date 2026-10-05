# Shared by every arbitration script. Source it; never run it.
ARB=/Users/benoitc/Projects/erlang_wasm-shared-pages/test/audit/raw/shared-pages/arbitration
P=/Users/benoitc/Projects
OUT=${OUT:-$ARB/results}
ARMS="base a3 a4 b"
GUESTS="py qjs lua"
LOAD_MAX=8

tree() {
  case $1 in
    base) echo $P/erlang_wasm-baseline-a2bda33;;
    a3)   echo $P/erlang_wasm-shared-pages;;
    a4)   echo $P/erlang_wasm-tlb2;;
    # B's HEAD exported with git archive, so work committed in
    # erlang_wasm-mmap during the run cannot change the arm.
    b)    echo $P/erlang_wasm-arb-b-435bace;;
    # Scratch first-write builds (inst/make.sh); never timed arms.
    inst-a3|inst-a4|inst-b) echo $P/erlang_wasm-arb-$1;;
    *)    echo "unknown arm $1" >&2; return 1;;
  esac
}
cachedir() { echo $HOME/.cache/wasm-arb/$1; }

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
  (cd $(tree $t) && erl -noshell +S 10:10 -pa _build/default/lib/wasm/ebin \
     -pa bench/arb "$@")
}

# Williams design for four arms: each arm precedes each other arm exactly
# once across rows 1-4 (rows are rounds). Rounds 5-8 repeat the four rows.
order() {
  case $(( ($1 - 1) % 4 )) in
    0) echo "base a3 b a4";;
    1) echo "a3 a4 base b";;
    2) echo "a4 b a3 base";;
    3) echo "b base a4 a3";;
  esac
}
