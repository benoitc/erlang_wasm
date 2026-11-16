#!/usr/bin/env bash
# Check the locked dependencies for known vulnerabilities and retired releases.
#
#   scripts/audit-deps.sh                     # every package in rebar.lock
#   scripts/audit-deps.sh plug 1.3.0 [...]    # named packages and versions
#
# Each package is checked at its locked version against two sources: the OSV
# database (api.osv.dev, ecosystem Hex), which carries the GitHub and EEF
# advisories, and hex.pm, where a release the author retired is marked. Either
# one fails the check. Dependabot does not read rebar.lock, so nothing else
# looks. Needs erl, curl and jq.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$#" -gt 0 ]; then
    PKGS="$(printf '%s %s\n' "$@" | xargs -n2)"
else
    # The lock is an Erlang term: read it with Erlang, not a pattern.
    PKGS="$(erl -noshell -eval '
        {ok, [{_Vsn, Deps} | _]} = file:consult("'"$ROOT"'/rebar.lock"),
        [io:format("~s ~s~n", [Pkg, Vsn]) || {_, {pkg, Pkg, Vsn}, _} <- Deps],
        halt().')"
fi

fail=0
while read -r name vsn; do
    [ -n "$name" ] || continue
    body=$(jq -cn --arg n "$name" --arg v "$vsn" \
             '{package: {name: $n, ecosystem: "Hex"}, version: $v}')
    vulns=$(curl -fsS https://api.osv.dev/v1/query -d "$body" \
              | jq -r '[.vulns[]?.id] | join(" ")')
    retired=$(curl -fsS "https://hex.pm/api/packages/$name/releases/$vsn" \
                | jq -r '.retirement // empty | "\(.reason): \(.message // "")"')
    if [ -n "$vulns" ]; then
        echo "$name $vsn: known vulnerabilities: $vulns"
        fail=1
    fi
    if [ -n "$retired" ]; then
        echo "$name $vsn: retired on hex.pm ($retired)"
        fail=1
    fi
    if [ -z "$vulns" ] && [ -z "$retired" ]; then
        echo "$name $vsn: no known vulnerability, not retired"
    fi
done <<< "$PKGS"
exit "$fail"
