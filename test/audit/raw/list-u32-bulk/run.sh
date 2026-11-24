#!/bin/sh
# PR E: per list length, 12 rounds alternating F and R, each a null pair
# (base, base) and an ab pair; a pair counts only if the 5-minute load average
# was below 8 at both ends of both runs; retried at most six times.
SP="$1"; OUT="$SP/e/time.terms"; : > "$OUT"
quiet() { while :; do L=$(sysctl -n vm.loadavg | awk '{print $3}'); awk "BEGIN{exit !($L < 8)}" && return; sleep 30; done; }
run() { quiet; T="$SP/e-$1"; (cd "$T" && ERL_LIBS="$T/_build/default/lib" erl -noshell -pa "$T" -run listbench main time "$2" 5) | tr -d '\n' | sed "s/^#{/#{side => $1, tag => \"$3\", /"; echo; }
ok() { echo "$1" | awk '{ s=$0; ok=1
  if (match(s, /load_start => [0-9.]+/)) { if (substr(s,RSTART+14,RLENGTH-14)+0 >= 8) ok=0 } else ok=0
  if (match(s, /load_end => [0-9.]+/)) { if (substr(s,RSTART+12,RLENGTH-12)+0 >= 8) ok=0 } else ok=0
  if (s !~ /round_us => [0-9]/) ok=0
  exit !ok }'; }
pair() { # n ordering round set first second
  for T in 1 2 3 4 5 6; do
    X=$(run "$5" "$1" "$1:$2:$3:$4:first"); Y=$(run "$6" "$1" "$1:$2:$3:$4:second")
    if ok "$X" && ok "$Y"; then printf '%s\n%s\n' "$X" "$Y" >> "$OUT"; return; fi
    printf '%s\n%s\n' "$X" "$Y" >> "$SP/e/discarded.terms"
  done
  echo "%% GAVE UP $1 $2 $3 $4" >> "$OUT"
}
for N in 16 4096 1000000; do
  for R in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [ $((R % 2)) = 1 ]; then pair $N F $R null base base; pair $N F $R ab base new
    else pair $N R $R ab new base; pair $N R $R null base base; fi
  done
done
echo done
