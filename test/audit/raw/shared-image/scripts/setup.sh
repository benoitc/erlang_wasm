#!/bin/bash
# setup.sh ARM...: build and harness for each arm's tree, and its manifest.
# The harness is the candidate's bench/paths (densitybench with poolstart,
# capture and churn), plus attrbench (saturated mode) from the A4
# attribution, byte-identical in every tree.
set -e
source $(dirname $0)/lib.sh
FILES="benchlib reactorlib barrier_adapter requestbench restorebench densitybench"
for t in "$@"; do
  d=$(tree $t)
  (cd $d && rebar3 compile > $R/build-$t.log 2>&1)
  mkdir -p $d/bench/si
  for f in $FILES; do cp $(tree cand)/bench/paths/$f.erl $d/bench/si/; done
  cp $R/scripts/attrbench.erl $d/bench/si/
  (cd $d && erlc -o bench/si -pa _build/default/lib/wasm/ebin bench/si/*.erl)
  {
    echo "== $t $d"
    echo "head $(git -C $d rev-parse HEAD)"
    git -C $d status --short src include c_src | sed 's/^/dirty /'
    echo "src_sha $(cat $d/src/*.erl $d/src/worker/*.erl $d/include/*.hrl | shasum -a 256 | cut -c1-16)"
    (cd $d/bench/si && shasum -a 256 *.erl)
  } > $R/manifest-$t.txt
  echo "setup $t done"
done
