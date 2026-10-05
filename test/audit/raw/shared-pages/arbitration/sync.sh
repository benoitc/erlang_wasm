#!/bin/bash
# Copy the bench sources into every arm's untracked bench/arb/, compile them
# there against that arm's ebin, and write the per-arm sha256 manifest. The
# run copied them from a bench/ directory here; they are kept in bench/paths,
# where only their module docs have changed since.
set -e
source $(dirname $0)/lib.sh
FILES="benchlib reactorlib requestbench restorebench densitybench realbench optbshare"
M=$ARB/manifest.txt
: > $M
for t in $ARMS inst-a3 inst-a4 inst-b; do
  d=$(tree $t)
  mkdir -p $d/bench/arb
  for f in $FILES; do cp $P/erlang_wasm-shared-pages/bench/paths/$f.erl $d/bench/arb/$f.erl; done
  (cd $d && erlc -o bench/arb -pa _build/default/lib/wasm/ebin \
     $(for f in $FILES; do echo bench/arb/$f.erl; done))
  echo "== $t $d" >> $M
  (cd $d && echo "head $(git rev-parse HEAD 2>/dev/null || cat ARB_SOURCE_SHA)" \
     && git status --short src test 2>/dev/null | sed 's/^/dirty /') >> $M
  (cd $d/bench/arb && shasum -a 256 $(for f in $FILES; do echo $f.erl; done)) >> $M
done
# Arm b must load an unsanitized NIF.
for t in b inst-b; do
  so=$(tree $t)/priv/wasm_mem_nif.so
  if nm $so | grep -q -E '__tsan_|__asan_'; then echo "SANITIZED NIF in $t"; exit 1; fi
  echo "nif $t $(shasum -a 256 $so | cut -c1-16) unsanitized" >> $M
done
# Every arm must carry byte-identical sources.
n=$(grep -E '\.erl$' $M | awk '{print $1, $2}' | sort -u | wc -l | tr -d ' ')
[ "$n" -eq $(echo $FILES | wc -w) ] || { echo "MISMATCH across arms"; exit 1; }
echo "synced $(echo $ARMS | wc -w) arms and 3 inst trees, $n distinct files"
