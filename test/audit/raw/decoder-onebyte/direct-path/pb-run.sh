#!/bin/sh
# PR A timing: per guest, 12 rounds alternating F and R, each a null pair
# (base, base) and an ab pair. A pair counts only if all four load readings
# are below 8; otherwise it is retried, at most six times.
SP="$1"; OUT="$SP/pb-out/time.terms"; : > "$OUT"
quiet() { while :; do L=$(sysctl -n vm.loadavg | awk '{print $3}'); awk "BEGIN{exit !($L < 8)}" && return; sleep 30; done; }
run() { quiet; (cd "$SP/pb-$1" && ERL_LIBS=_build/default/lib erl -noshell -pa "$SP/pb-$1" -run compilephases main time "$2" 5) | tr -d '\n' | sed "s/^#{/#{side => $1, tag => \"$3\", /"; echo; }
ok() { echo "$1" | awk '{ s=$0; ok=1
  if (match(s, /load_start => [0-9.]+/)) { if (substr(s,RSTART+14,RLENGTH-14)+0 >= 8) ok=0 } else ok=0
  if (match(s, /load_end => [0-9.]+/)) { if (substr(s,RSTART+12,RLENGTH-12)+0 >= 8) ok=0 } else ok=0
  exit !ok }'; }
pair() { # guest ordering round set first second
  for T in 1 2 3 4 5 6; do
    X=$(run "$5" "$1" "$1:$2:$3:$4:first"); Y=$(run "$6" "$1" "$1:$2:$3:$4:second")
    if ok "$X" && ok "$Y"; then printf '%s\n%s\n' "$X" "$Y" >> "$OUT"; return; fi
    printf '%s\n%s\n' "$X" "$Y" >> "$SP/pb-out/discarded.terms"
  done
  echo "%% GAVE UP $1 $2 $3 $4" >> "$OUT"
}
for G in qjs python; do
  for R in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [ $((R % 2)) = 1 ]; then pair $G F $R null base base; pair $G F $R ab base new
    else pair $G R $R ab new base; pair $G R $R null base base; fi
  done
done
echo done
