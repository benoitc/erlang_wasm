#!/bin/bash
S=$1
for r in 1 2 3; do if [ $r = 2 ]; then o="null cand main"; else o="main cand null"; fi
for a in $o; do (cd /Users/benoitc/Projects/ewbench-$a && erl -noshell +S 10:10 -pa _build/default/lib/*/ebin -pa bench/paths -pa $S/ld/$a -run loaddiag main qjs,plain,lua,py 200 $S/ld/$a-r$r.terms > /dev/null 2>&1); done; done
