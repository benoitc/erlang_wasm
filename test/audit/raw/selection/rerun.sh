#!/bin/sh
# Reruns the load-invalid pairs of experiment S, both sides in their original
# order. Waits for load < 8 before every run; a pair counts only if all four
# endpoints (start and end of both runs) are below 8, and is retried otherwise,
# at most six times.
SP="$1"; ST="$SP/stree"; OUT="$SP/sel/rerun.terms"
BASE=""; S1="46,47,48"; S2="158"
excl() { case "$1" in null) echo "$BASE";; s1) echo "$S1";; s2) echo "$S2";; esac; }
quiet() { while :; do L=$(sysctl -n vm.loadavg | awk '{print $2}'); awk "BEGIN{exit !($L < 8)}" && return; sleep 30; done; }
run() { quiet; (cd "$ST" && ERL_LIBS="$ST/_build/default/lib" erl -noshell -pa "$SP" -run selbench main time "$1" "$2"); }
ok() { # a run's printed map, both loads below 8
  echo "$1" | tr -d '\n' | awk '{ s=$0; ok=1
    if (match(s, /load_start => [0-9.]+/)) { v=substr(s,RSTART+14,RLENGTH-14); if (v+0 >= 8) ok=0 } else ok=0
    if (match(s, /load_end => [0-9.]+/)) { v=substr(s,RSTART+12,RLENGTH-12); if (v+0 >= 8) ok=0 } else ok=0
    exit !ok }'
}
pair() { # set ordering round
  S="$1"; O="$2"; R="$3"; V=$(excl "$S")
  if [ "$O" = F ]; then A="$BASE"; B="$V"; else A="$V"; B="$BASE"; fi
  [ "$S" = null ] && { A="$BASE"; B="$BASE"; }
  for T in 1 2 3 4 5 6; do
    X=$(run "$A" "$O:$R:$S:first:rerun$T") || exit 1
    Y=$(run "$B" "$O:$R:$S:second:rerun$T") || exit 1
    if ok "$X" && ok "$Y"; then printf '%s\n%s\n' "$X" "$Y" >> "$OUT"; return; fi
    printf '%%%% discarded %s %s %s attempt %s\n' "$S" "$O" "$R" "$T" >> "$OUT"
    printf '%s\n%s\n' "$X" "$Y" >> "$SP/sel/discarded.terms"
  done
  printf '%%%% GAVE UP %s %s %s\n' "$S" "$O" "$R" >> "$OUT"
}
# Round by round, each round's invalid pairs in their original order:
# forward rounds ran null, s1, s2; reverse rounds s1, s2, null.
pair null F 1
pair s1 R 2; pair s2 R 2; pair null R 2
pair null F 3; pair s1 F 3; pair s2 F 3
pair null R 4
pair null F 5; pair s1 F 5; pair s2 F 5
pair s1 R 6; pair s2 R 6; pair null R 6
pair null F 7; pair s1 F 7; pair s2 F 7
pair s1 R 8; pair s2 R 8; pair null R 8
pair null F 9; pair s1 F 9; pair s2 F 9
echo done
