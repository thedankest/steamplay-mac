#!/bin/bash
# Applies patches/notproton/*.patch to the notproton submodule, in name order, each exactly once.
#
# The patches form a series: a later one may change lines an earlier one added (0003 wires
# autofix into the fix-file block that 0001 adds), so "is patch N applied?" cannot be answered
# for N alone. The tree has patches 1..k applied when reversing k, k-1, ..., 1 in that order
# succeeds on a scratch copy of the touched files. The highest such k is found, then patches
# k+1..n are applied in order, and the result is checked the same way.
#
# Usage: scripts/apply-notproton-patches.sh [--check]
#   --check   change nothing; print how many are applied; exit 0 only if all of them are
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NP="$ROOT/notproton"
CHECK=0
[ "${1:-}" = --check ] && CHECK=1

patches=()
for p in "$ROOT"/patches/notproton/*.patch; do
    [ -f "$p" ] && patches+=("$p")
done
n=${#patches[@]}
[ "$n" -gt 0 ] || { echo "no patches in patches/notproton"; exit 0; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/np-patches.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
files="$(sed -n 's#^+++ b/##p' "${patches[@]}" | sort -u)"

# Largest k such that patches k..1 reverse cleanly, in that order, on a copy of the tree.
applied_prefix() {
    local k i f
    for ((k = n; k >= 1; k--)); do
        rm -rf "$SCRATCH/t"
        mkdir -p "$SCRATCH/t"
        while IFS= read -r f; do
            [ -n "$f" ] && [ -f "$NP/$f" ] || continue
            mkdir -p "$SCRATCH/t/$(dirname "$f")"
            cp -p "$NP/$f" "$SCRATCH/t/$f"
        done <<< "$files"
        for ((i = k - 1; i >= 0; i--)); do
            (cd "$SCRATCH/t" && git apply --reverse "${patches[$i]}" 2>/dev/null) || continue 2
        done
        echo "$k"
        return 0
    done
    echo 0
}

k="$(applied_prefix)"
if [ "$CHECK" = 1 ]; then
    echo "notproton patches applied: $k of $n"
    [ "$k" = "$n" ]
    exit
fi
for ((i = k; i < n; i++)); do
    git -C "$NP" apply "${patches[$i]}" || { echo "notproton patch failed: ${patches[$i]}" >&2; exit 1; }
    echo "applied ${patches[$i]##*/}"
done
k="$(applied_prefix)"
[ "$k" = "$n" ] || { echo "after applying, only $k of $n notproton patches are recognised as applied" >&2; exit 1; }
echo "notproton patches: all $n applied"
