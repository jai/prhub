#!/bin/zsh
# Xcode Cloud, after each xcodebuild action, from app/ci_scripts. After the PRHub Release workflow's archive it writes
# the build's What to Test, its version's section of CHANGELOG.md (release.sh), to app/TestFlight/WhatToTest.en-US.txt,
# where Xcode Cloud reads it when it hands the build to TestFlight. release/what-to-test.sh cuts it to Apple's
# 4000-byte limit.
set -euo pipefail
if [[ ${CI_XCODEBUILD_ACTION:-} != archive || ${CI_XCODEBUILD_EXIT_CODE:-1} != 0 ]]; then
    exit 0
fi
source "${0:A:h}/release.sh"
if [[ -z $release_notes ]]; then
    exit 0
fi
dir=$CI_PRIMARY_REPOSITORY_PATH/app/TestFlight
mkdir -p "$dir"
printf '%s' "$release_notes" > "$dir/WhatToTest.en-US.txt"
echo "What to Test: $(cat "$dir/WhatToTest.en-US.txt")"
