#!/bin/sh
# PR C timing: 12 rounds alternating F and R, each a null pair (base, base)
# and an ab pair (base, new). A pair counts only if the 5-minute load average
# was below 8 at both ends of both runs; else it is retried, at most six times.
SP="$1"; OUT="$SP/c2/time.terms"
quiet() { while :; do L=$(sysctl -n vm.loadavg | awk '{print $3}'); awk "BEGIN{exit !($L < 8)}" && return; sleep 30; done; }
run() { quiet; T="$SP/c2-$1"; (cd "$T" && ERL_LIBS="$T/_build/default/lib" erl -noshell -pa "$SP/c2" -run tlbbench main time "" "$2") | tr -d '\n' | sed "s/^#{/#{side => $1, /"; echo; }
ok() { echo "$1" | awk '{ s=$0; ok=1
  if (match(s, /load_start => [0-9.]+/)) { if (substr(s,RSTART+14,RLENGTH-14)+0 >= 8) ok=0 } else ok=0
  if (match(s, /load_end => [0-9.]+/)) { if (substr(s,RSTART+12,RLENGTH-12)+0 >= 8) ok=0 } else ok=0
  if (s ~ /failed => \{/) ok=0
  exit !ok }'; }
pair() { # ordering round set first second
  for T in 1 2 3 4 5 6; do
    X=$(run "$4" "$1:$2:$3:first"); Y=$(run "$5" "$1:$2:$3:second")
    if ok "$X" && ok "$Y"; then printf '%s\n%s\n' "$X" "$Y" >> "$OUT"; return; fi
    printf '%s\n%s\n' "$X" "$Y" >> "$SP/c2/discarded.terms"
  done
  echo "%% GAVE UP $1 $2 $3" >> "$OUT"
}
for R in 4 5 6 7 8 9 10 11 12; do
  if [ $((R % 2)) = 1 ]; then pair F $R null base base; pair F $R ab base new
  else pair R $R ab new base; pair R $R null base base; fi
done
echo done
