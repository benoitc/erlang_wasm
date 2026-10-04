#!/bin/bash
# The breakdown on macOS: both trees (scratch copies, see below), both guests,
# one fresh VM each. Counts do not depend on load; it is recorded anyway.
#   paged: /Users/benoitc/Projects/erlang_wasm-dens-paged (git archive tlb2 9230dbf)
#   mmap:  /Users/benoitc/Projects/erlang_wasm-dens-mmap  (copy of arb-b-435bace)
set -euo pipefail
D=$(cd $(dirname $0) && pwd)
mkdir -p $D/macos
for a in paged mmap; do
  (cd /Users/benoitc/Projects/erlang_wasm-dens-$a && mkdir -p $D/ebin-$a &&
   erlc -o $D/ebin-$a -pa _build/default/lib/wasm/ebin $D/densbreak.erl)
done
run() { (cd /Users/benoitc/Projects/erlang_wasm-dens-$1 && erl -noshell +S 10:10 \
  -pa _build/default/lib/wasm/ebin -pa bench/arb -pa $D/ebin-$1 \
  -run densbreak main $2 $D/macos/$2_$1.terms > $D/macos/$2_$1.txt 2>&1); }
uptime > $D/macos/load.txt
run mmap py & run paged py & run mmap py_entry & run paged py_entry & wait
uptime >> $D/macos/load.txt
escript $D/purchases.escript $D/macos/*.terms
