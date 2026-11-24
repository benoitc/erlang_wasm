#!/bin/sh
# PR C restored-memory gate: requestbench split py_entry compiled, 12 rounds
# alternating F and R, each a null pair and an ab pair. A pair counts only if
# the 5-minute load average was below 8 at both ends of both runs, and both
# runs answered verdict ok; else it is retried, at most six times.
SP="$1"; OUT="$SP/c4/time.terms"; : > "$OUT"
load5() { sysctl -n vm.loadavg | awk '{print $3}'; }
quiet() { while :; do L=$(load5); awk "BEGIN{exit !($L < 8)}" && return; sleep 30; done; }
run() { quiet; case "$1" in base) T="$SP/c2-base";; new) T="$SP/c3-new";; esac
  L0=$(load5)
  R=$( (cd "$T" && ERL_LIBS=_build/default/lib erl -noshell +S 10:10 -pa "$SP/c4/beam" -run requestbench main split py_entry compiled off none none 2>/dev/null) | grep -v "^=WARNING\|code_cache_dir\|^ *\"/" | tr -d '\n')
  L1=$(load5)
  echo "$R" | sed -e "s/^#{/#{side => $1, tag => \"$2\", load_start => $L0, /" -e "s/}\$/, load_end => $L1}./"; }
ok() { echo "$1" | awk '{ s=$0; ok=1
  if (match(s, /load_start => [0-9.]+/)) { if (substr(s,RSTART+14,RLENGTH-14)+0 >= 8) ok=0 } else ok=0
  if (match(s, /load_end => [0-9.]+/)) { if (substr(s,RSTART+12,RLENGTH-12)+0 >= 8) ok=0 } else ok=0
  if (s !~ /verdict => ok/) ok=0
  exit !ok }'; }
pair() {
  for T in 1 2 3 4 5 6; do
    X=$(run "$4" "$1:$2:$3:first"); Y=$(run "$5" "$1:$2:$3:second")
    if ok "$X" && ok "$Y"; then printf '%s\n%s\n' "$X" "$Y" >> "$OUT"; return; fi
    printf '%s\n%s\n' "$X" "$Y" >> "$SP/c4/discarded.terms"
  done
  echo "%% GAVE UP $1 $2 $3" >> "$OUT"
}
for R in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if [ $((R % 2)) = 1 ]; then pair F $R null base base; pair F $R ab base new
  else pair R $R ab new base; pair R $R null base base; fi
done
echo done
