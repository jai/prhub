#!/bin/zsh
# Xcode Cloud, after each xcodebuild action, from app/ci_scripts. After an archive it writes the build's What to Test,
# a release's `chore(release): PRHub build N — …` subject (release.sh) or else the pushed commit's subject, to
# app/TestFlight/WhatToTest.en-US.txt, where Xcode Cloud reads it when it hands the build to TestFlight. Cut to Apple's
# 4000-byte limit, as release/testflight.swift does for local uploads.
set -euo pipefail
if [[ ${CI_XCODEBUILD_ACTION:-} != archive || ${CI_XCODEBUILD_EXIT_CODE:-1} != 0 ]]; then
    exit 0
fi
source "${0:A:h}/release.sh"
if [[ -z $release_notes ]]; then
    # A build of any push: what it brings is its commit's subject.
    release_notes=$(git -C "$CI_PRIMARY_REPOSITORY_PATH" log -1 --format=%s)
fi
dir=$CI_PRIMARY_REPOSITORY_PATH/app/TestFlight
mkdir -p "$dir"
printf '%s' "$release_notes" | head -c 4000 > "$dir/WhatToTest.en-US.txt"
echo "What to Test: $(cat "$dir/WhatToTest.en-US.txt")"
