#!/bin/bash
# erlang_wasm against plain Erlang and erlang-wasmtime, a fixed baseline commit
# against the candidate working tree.
#
# Usage: run.sh BASELINE_COMMIT QJS_WASM OUTDIR [ROUNDS] [WASMTIME_EBIN]
#
# Each round runs four arms, one fresh VM each, in a rotating order:
# baseline, candidate, erlang (the plain-Erlang reference) and wasmtime; then
# the cold compile on baseline and candidate. A run starts only below a
# one-minute load of 8 and is redone (up to three attempts) when it ends at 8
# or more; if it still does, its result is renamed .overloaded and the whole
# round is redone, up to three times, after which the script fails. Any arm
# that fails stops the script. summary.escript reads OUTDIR.
set -euo pipefail
BASE=$1; QJS=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); OUT=$3
ROUNDS=${4:-5}
WT=${5:-$HOME/Projects/erlang-wasmtime/_build/default/lib/erlang_wasmtime/ebin}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HARNESS=$ROOT/bench/cross/vs
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
cd "$ROOT"

# ---------------------------------------------------------------- the trees
# Built from git, never in place: the baseline from its commit, the candidate
# from the working tree as it is now (tracked and untracked, not ignored).
TREES=$OUT/trees
rm -rf "$TREES"; mkdir -p "$TREES/baseline" "$TREES/candidate"
git archive "$BASE" | tar -x -C "$TREES/baseline"
git ls-files -co --exclude-standard -z | tar --null -T - -c | tar -x -C "$TREES/candidate"
for t in baseline candidate; do
  (cd "$TREES/$t" && rebar3 compile > build.log 2>&1) || { echo "build of $t failed"; exit 1; }
done
WTCOMMIT=$(git -C "$WT/../../../.." rev-parse --short HEAD 2>/dev/null || echo unknown)
OTP=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().')
{
  echo "tree baseline"
  echo "commit $(git rev-parse "$BASE")"
} > "$TREES/baseline/MANIFEST"
{
  echo "tree candidate"
  echo "commit $(git rev-parse HEAD)"
  echo "diff $(git diff HEAD | shasum -a 256 | cut -c1-16)"
  echo "untracked $(git ls-files -o --exclude-standard | shasum -a 256 | cut -c1-16)"
} > "$TREES/candidate/MANIFEST"
for t in baseline candidate; do
  echo "otp $OTP" >> "$TREES/$t/MANIFEST"
done
{
  echo "tree reference"
  echo "harness $(git rev-parse HEAD)"
  echo "wasmtime_binding $WTCOMMIT"
  echo "otp $OTP"
} > "$OUT/REFERENCE"

# -------------------------------------------------------------- the harness
# One copy, compiled once, used by every arm: only the runtime on the code
# path differs between baseline and candidate.
wasm-tools parse bench/cross/loop.wat -o bench/cross/loop.wasm
for f in mem fib bulk nop; do
  wasm-tools parse "$HARNESS/$f.wat" -o "$HARNESS/$f.wasm"
done
erlc -o "$HARNESS" -pa "$TREES/candidate/_build/default/lib/wasm/ebin" \
    bench/paths/gapref.erl "$HARNESS/vs.erl"

# ----------------------------------------------------------------- the runs
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
# VS_LOAD_LIMIT lowers the limit only to show that an overloaded round is
# set aside and, three times over, fails the run.
LIMIT=${VS_LOAD_LIMIT:-8}
below8() { awk -v l="$1" -v m="$LIMIT" 'BEGIN{exit !(l < m)}'; }
startable() { awk -v l="$1" 'BEGIN{exit !(l < 8)}'; }
wait_quiet() { until startable "$(load1)"; do sleep 20; done; }

# run NAME KIND LABEL PATHS MANIFEST: one arm in one fresh VM, up to three
# attempts against load. Returns 2 when it is still overloaded.
run() {
  local name=$1 kind=$2 label=$3 paths=$4 man=$5 l0 l1 a
  for a in 1 2 3; do
    wait_quiet; l0=$(load1)
    # A cold compile must start from an empty cache, on every attempt.
    rm -rf "$OUT/$name.terms" "$OUT/$name.cache"
    # shellcheck disable=SC2086
    if ! erl -noshell +S 10:10 $paths -pa "$HARNESS" \
        -run vs main "$kind" "$label" "$QJS" "$OUT/$name.terms" "$man" \
        > "$OUT/$name.out" 2>&1; then
      echo "$name failed; see $OUT/$name.out"; exit 1
    fi
    l1=$(load1)
    echo "$name attempt$a load $l0 -> $l1" >> "$OUT/loads.log"
    below8 "$l1" && return 0
  done
  mv "$OUT/$name.terms" "$OUT/$name.overloaded"
  return 2
}

paths_of() { echo "-pa $TREES/$1/_build/default/lib/*/ebin"; }

# VS_ARMS and VS_COLD=0 narrow a run, only to exercise the checks quickly;
# a summary refuses a directory that does not hold every arm.
read -r -a ARMS <<< "${VS_ARMS:-baseline candidate erlang wasmtime}"
NARMS=${#ARMS[@]}
for r in $(seq 1 "$ROUNDS"); do
  for rattempt in 1 2 3; do
    ok=1
    # Rotate: round r starts with arm (r-1) mod 4.
    for i in $(seq 0 $((NARMS - 1))); do
      arm=${ARMS[$(( (r - 1 + i) % NARMS ))]}
      case $arm in
        baseline|candidate) kind=erlang_wasm; p=$(paths_of "$arm"); m=$TREES/$arm/MANIFEST ;;
        erlang) kind=erlang; p=""; m=$OUT/REFERENCE ;;
        wasmtime) kind=wasmtime; p="-pa $WT"; m=$OUT/REFERENCE ;;
      esac
      run "$arm-r$r" "$kind" "$arm" "$p" "$m" || { ok=0; break; }
    done
    if [ $ok = 1 ] && [ "${VS_COLD:-1}" != 0 ]; then
      if [ $((r % 2)) = 1 ]; then cold="baseline candidate"; else cold="candidate baseline"; fi
      for t in $cold; do
        run "cold-$t-r$r" coldcompile "$t" "$(paths_of "$t")" "$TREES/$t/MANIFEST" || { ok=0; break; }
      done
    fi
    if [ $ok = 1 ]; then break; fi
    # Overloaded: set the whole round aside and run it again.
    mkdir -p "$OUT/rejected/r$r-attempt$rattempt"
    mv "$OUT"/*-r"$r".* "$OUT/rejected/r$r-attempt$rattempt/" 2>/dev/null || true
    if [ "$rattempt" = 3 ]; then echo "round $r overloaded three times"; exit 1; fi
  done
done
echo DONE >> "$OUT/loads.log"
