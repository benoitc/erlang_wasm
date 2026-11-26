#!/bin/sh
# PR F stage 1, PR F stage 2, then PR G, one after another. Every timed set:
# 12 rounds alternating F and R, each a null pair (base, base) and an ab pair;
# a pair counts only if the 5-minute load average was below 8 at both ends of
# both runs and the run did not fail; retried at most six times.
SP="$1"; G="$SP/gates"
quiet() { while :; do L=$(sysctl -n vm.loadavg | awk '{print $3}'); awk "BEGIN{exit !($L < 8)}" && return; sleep 30; done; }
okrun() { echo "$1" | awk -v want="$2" '{ s=$0; ok=1
  if (match(s, /load_start => [0-9.]+/)) { if (substr(s,RSTART+14,RLENGTH-14)+0 >= 8) ok=0 } else ok=0
  if (match(s, /load_end => [0-9.]+/)) { if (substr(s,RSTART+12,RLENGTH-12)+0 >= 8) ok=0 } else ok=0
  if (s ~ /failed => \{/) ok=0
  if (s !~ want) ok=0
  exit !ok }'; }
# set: name base_dir new_dir kind args...; kind is copy, qjs or wat
one() { # kind dir arg tag side
  quiet
  case "$1" in
    copy) D=${3%%:*}; S=${3#*:}; R=$( (cd "$2" && ERL_LIBS="$2/_build/default/lib" erl -noshell -pa "$2" -run copybench main "$D" "$S" 65536 5) | tr -d '\n');;
    qjs) R=$( (cd "$2" && ERL_LIBS="$2/_build/default/lib" erl -noshell -pa "$SP/c2" -run tlbbench main time "" "$4") | tr -d '\n');;
    wat) R=$( (cd "$2" && ERL_LIBS="$2/_build/default/lib" erl -noshell -pa "$2" -pa /Users/benoitc/Projects/erlang_wasm/_build/test/lib/wasm/test -run watbench main corpus 5) | tr -d '\n');;
  esac
  echo "$R" | sed "s/^#{/#{side => $5, tag => \"$4\", /"
}
want() { case "$1" in copy) echo "copy_us => [0-9]";; qjs) echo "cold_us => [0-9]";; wat) echo "corpus_us => [0-9]";; esac; }
pair() { # out kind base new arg ordering round set first second
  OUT=$1; K=$2; B=$3; N=$4; A=$5; O=$6; R=$7; S=$8
  dir() { case "$1" in base) echo "$B";; new) echo "$N";; esac; }
  for T in 1 2 3 4 5 6; do
    X=$(one "$K" "$(dir $9)" "$A" "$A:$O:$R:$S:first" "$9"); Y=$(one "$K" "$(dir ${10})" "$A" "$A:$O:$R:$S:second" "${10}")
    if okrun "$X" "$(want $K)" && okrun "$Y" "$(want $K)"; then printf '%s\n%s\n' "$X" "$Y" >> "$OUT"; return; fi
    printf '%s\n%s\n' "$X" "$Y" >> "$OUT.discarded"
  done
  echo "%% GAVE UP $A $O $R $S" >> "$OUT"
}
set12() { # out kind base new arg
  for R in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [ $((R % 2)) = 1 ]; then pair "$1" "$2" "$3" "$4" "$5" F $R null base base; pair "$1" "$2" "$3" "$4" "$5" F $R ab base new
    else pair "$1" "$2" "$3" "$4" "$5" R $R ab new base; pair "$1" "$2" "$3" "$4" "$5" R $R null base base; fi
  done
}
mkdir -p "$G/f1" "$G/f2" "$G/g"
: > "$G/f1/copy.terms"; for C in 8:0 65536:0; do set12 "$G/f1/copy.terms" copy "$SP/f-base" "$SP/f-s1" "$C"; done
: > "$G/f1/qjs.terms"; set12 "$G/f1/qjs.terms" qjs "$SP/f-base" "$SP/f-s1" qjs
: > "$G/f2/copy.terms"; for C in 65537:0 9:0 65536:0; do set12 "$G/f2/copy.terms" copy "$SP/f-base" "$SP/f-new" "$C"; done
: > "$G/f2/qjs.terms"; set12 "$G/f2/qjs.terms" qjs "$SP/f-base" "$SP/f-new" qjs
: > "$G/g/corpus.terms"; set12 "$G/g/corpus.terms" wat "$SP/g-base" "$SP/g-new" corpus
for S in base new; do for N in 2000 8000; do (cd "$SP/g-$S" && ERL_LIBS="$SP/g-$S/_build/default/lib" erl -noshell -pa "$SP/g-$S" -run watbench main scale $N) | tr -d '\n' | sed "s/^#{/#{side => $S, /" >> "$G/g/scale.terms"; echo >> "$G/g/scale.terms"; done; done
echo done
