#!/bin/sh
# Make DEST a checkout of REF, a commit or a tag, fetched shallowly from URL.
#
#   scripts/checkout-pin.sh DEST URL REF
#
# The upstream suites are pinned, and the fetch scripts used to skip the fetch
# whenever DEST existed. A checkout left at another commit was then used
# silently, and moving a pin changed nothing: conformance was reported against
# a different suite than the one the repository declares. So an existing
# checkout is checked against the pin:
#
#   at REF already           left alone, nothing fetched
#   elsewhere, unchanged     moved to REF, and the move is printed
#   elsewhere, with changes  stop: the changes are yours to keep or drop
#   not a git checkout       stop: delete it and run again
#
# For a tag, the checkout is at REF when its own tag of that name resolves to
# HEAD; `git clone --branch' makes that tag, so no fetch is needed to tell.
set -eu

dest=$1 url=$2 ref=$3

fetch() {
    git -C "$dest" fetch -q --depth 1 "$url" "$ref"
    git -C "$dest" checkout -q FETCH_HEAD
}

if [ ! -e "$dest" ]; then
    git init -q "$dest"
    fetch
    exit 0
fi

if ! git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
   [ "$(git -C "$dest" rev-parse --show-toplevel)" != "$(cd "$dest" && pwd -P)" ]
then
    echo "$dest: not a git checkout; delete it and run again" >&2
    exit 1
fi

head=$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo none)
want=$(git -C "$dest" rev-parse -q --verify "refs/tags/$ref^{commit}" 2>/dev/null ||
       echo "$ref")
if [ "$head" = "$want" ]; then
    exit 0
fi

if [ -n "$(git -C "$dest" status --porcelain --untracked-files=no)" ]; then
    echo "$dest: at $head, but the pin is $ref, and tracked files are changed." >&2
    echo "Commit or discard the changes, or delete $dest, then run again." >&2
    exit 1
fi

fetch
echo "$dest: moved from $head to $(git -C "$dest" rev-parse HEAD) ($ref)"
