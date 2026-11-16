#!/bin/zsh
# Xcode Cloud, after each xcodebuild action, from app/ci_scripts. After an archive it writes the build's What to Test,
# the notes of the version tag on the commit (the message of the annotated vX.Y.Z tag release/version.mjs made), else
# the commit's subject, to
# app/TestFlight/WhatToTest.en-US.txt, where Xcode Cloud reads it when it hands the build to TestFlight. Cut to Apple's
# 4000-byte limit: tag notes by whole lines. A tag signed by hand
# carries its signature at the end of its message; the notes stop before it.
set -euo pipefail
if [[ ${CI_XCODEBUILD_ACTION:-} != archive || ${CI_XCODEBUILD_EXIT_CODE:-1} != 0 ]]; then
    exit 0
fi
release_notes=
repo_git=(git -C "$CI_PRIMARY_REPOSITORY_PATH")
if [[ -z $release_notes ]]; then
    tag=$("${repo_git[@]}" tag --points-at HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)
    if [[ -n $tag && $("${repo_git[@]}" cat-file -t "refs/tags/$tag") == tag ]]; then
        release_notes=$("${repo_git[@]}" tag --list --format='%(contents)' "$tag" \
            | sed '/^-----BEGIN [A-Z ]*SIGNATURE-----$/,$d' \
            | LC_ALL=C awk -v max=4000 'NF { n += length($0) + 1; if (n > max + 1) exit; print }')
    fi
fi
if [[ -z $release_notes ]]; then
    # A build of any other push: what it brings is its commit's subject.
    release_notes=$("${repo_git[@]}" log -1 --format=%s)
fi
dir=$CI_PRIMARY_REPOSITORY_PATH/app/TestFlight
mkdir -p "$dir"
printf '%s' "$release_notes" | head -c 4000 > "$dir/WhatToTest.en-US.txt"
echo "What to Test: $(cat "$dir/WhatToTest.en-US.txt")"
