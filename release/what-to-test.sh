#!/bin/zsh
# Prints TestFlight's What to Test for PRHub <version>: that version's section of CHANGELOG.md, which release-please
# writes from the conventional commits, as plain text cut at a line to Apple's 4000-byte limit. Fails when CHANGELOG.md
# has no section for <version>. Run by release/ship.sh and app/ci_scripts/ci_post_xcodebuild.sh:
#   release/what-to-test.sh <version>
set -euo pipefail
version=${1:?usage: release/what-to-test.sh <version>}
changelog=${0:A:h}/../CHANGELOG.md
[[ -f $changelog ]] || { echo "no CHANGELOG.md" >&2; exit 1; }
# A version heading is `## [0.17.0](compare link) (date)`; the section runs to the next one.
section=$(awk -v v="$version" '
    /^#+ \[?[0-9]+\.[0-9]+\.[0-9]+/ {
        if (found) exit
        heading = $2
        gsub(/^\[|\].*$/, "", heading)
        found = heading == v
        next
    }
    found
' "$changelog")
[[ -n ${section//[[:space:]]/} ]] || { echo "CHANGELOG.md has no section for $version" >&2; exit 1; }
# Plain text: no commit links, issue links as (#21), no bold, headings and bullets without markdown.
print -r -- "$section" | sed -E \
    -e 's/ \(\[[0-9a-f]{7,40}\]\([^)]*\)\)//g' \
    -e 's/\[(#[0-9]+)\]\([^)]*\)/\1/g' \
    -e 's/\*\*([^*]+)\*\*/\1/g' \
    -e 's/^#+ //' \
    -e 's/^\* /- /' \
    | cat -s | sed -e '/./,$!d' \
    | LC_ALL=C awk '{ total += length($0) + 1; if (total > 4000) exit; print }' \
    | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
