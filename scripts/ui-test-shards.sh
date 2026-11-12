#!/usr/bin/env bash
# ui-test-shards.sh — the UI tests' slices for CI, from app/PRHubUITests/shards.txt.
#
#   scripts/ui-test-shards.sh args <slice>   xcodebuild's -only-testing arguments for one slice
#   scripts/ui-test-shards.sh check          fails unless every UI test is in exactly one slice
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tests="$root/app/PRHubUITests"
shards="$tests/shards.txt"

entries() {
    grep --color=never -v '^[[:space:]]*\(#\|$\)' "$shards"
}

case "${1:-}" in
args)
    slice="${2:?usage: ui-test-shards.sh args <slice>}"
    entries | awk -v slice="$slice" '$1 == slice { printf "-only-testing:PRHubUITests/%s\n", $2 }'
    ;;
check)
    expected=$(for file in "$tests"/*.swift; do
        class=$(sed -n 's/^.*final class \([A-Za-z0-9_]*\): XCTestCase.*$/\1/p' "$file")
        [ -n "$class" ] || continue
        sed -n "s/^[[:space:]]*func \(test[A-Za-z0-9_]*\)(.*$/$class\/\1/p" "$file"
    done | sort)
    covered=$(entries | awk '{ print $2 }' | while read -r entry; do
        case "$entry" in
        */*) echo "$entry" ;;
        *) printf '%s\n' "$expected" | grep --color=never "^$entry/" || echo "$entry/(no such class)" ;;
        esac
    done | sort)
    missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$covered" | sort -u))
    extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$covered" | sort -u))
    twice=$(printf '%s\n' "$covered" | uniq -d)
    status=0
    [ -z "$missing" ] || { echo "ui-test-shards: in no slice of $shards:"; echo "$missing"; status=1; }
    [ -z "$extra" ] || { echo "ui-test-shards: in $shards but not a test:"; echo "$extra"; status=1; }
    [ -z "$twice" ] || { echo "ui-test-shards: in more than one slice:"; echo "$twice"; status=1; }
    [ "$status" = 0 ] && echo "ui-test-shards: $(printf '%s\n' "$expected" | wc -l | tr -d ' ') UI tests, each in one slice"
    exit "$status"
    ;;
*)
    echo "usage: ui-test-shards.sh args <slice> | check" >&2
    exit 2
    ;;
esac
