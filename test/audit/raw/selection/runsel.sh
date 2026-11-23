#!/bin/sh
# Experiment S driver. One VM per run; waits for load < 8 before each pair.
SP="$1"; ST="$SP/stree"; OUT="$SP/sel"; mkdir -p "$OUT"
run() { (cd "$ST" && ERL_LIBS="$ST/_build/default/lib" erl -noshell -pa "$SP" -run selbench main "$@"); }
quiet() { while :; do L=$(sysctl -n vm.loadavg | awk '{print $2}'); awk "BEGIN{exit !($L < 8)}" && return; sleep 30; done; }
BASE=""; S1="46,47,48"; S2="158"
for E in "$BASE" "$S1" "$S2"; do run cross "$E" "cross" >> "$OUT/cross.terms" || { echo "cross failed $E"; exit 1; }; done
pair() { # ordering round set first second
  quiet; run time "$4" "$1:$2:$3:first" >> "$OUT/time.terms" || exit 1
  run time "$5" "$1:$2:$3:second" >> "$OUT/time.terms" || exit 1
}
for R in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if [ $((R % 2)) = 1 ]; then
    pair F $R null "$BASE" "$BASE"; pair F $R s1 "$BASE" "$S1"; pair F $R s2 "$BASE" "$S2"
  else
    pair R $R s1 "$S1" "$BASE"; pair R $R s2 "$S2" "$BASE"; pair R $R null "$BASE" "$BASE"
  fi
done
echo done
