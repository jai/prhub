#!/bin/zsh
# Xcode Cloud, after the clone, from app/ci_scripts. The project is generated (*.xcodeproj is gitignored), so this
# installs XcodeGen and generates app/PRHub.xcodeproj before Xcode Cloud opens it. In the PRHub Release workflow it
# first checks the commit is a release (release.sh) and sets CURRENT_PROJECT_VERSION to Xcode Cloud's build number,
# which is the number TestFlight shows. release/next-build.sh picks N so the two agree; when they do not, Xcode Cloud's
# number wins and this says so.
# Xcode Cloud resolves packages only from a Package.resolved, and the generated project has none: app/Package.resolved
# pins the remote ones (PostHog) and goes into the project here. Refresh it when project.yml's packages change:
# `xcodebuild -resolvePackageDependencies` in app/, then copy the project's Package.resolved back to app/.
# In every workflow it sets MARKETING_VERSION to the newest vX.Y.Z tag reachable from the commit (release/version.mjs
# makes them from conventional commits; nobody edits MARKETING_VERSION). The clone can be shallow and without tags.
# In the Internal - TestFlight workflow it marks the build as the Internal group's (PRHUB_INTERNAL_TESTFLIGHT).
# In the PRHub Tests workflow it runs PRKit's `swift test` here, on the one Mac with the sources: the test Macs get only
# the built products, so the PRHub scheme's PRKitTests skip what reads docs/fixtures/, and the Mac's code runs only here.
# That workflow is known by its id, which a rename leaves alone; where Xcode Cloud gives no id, every run that is not a
# release runs the tests.
set -euo pipefail
source "${0:A:h}/release.sh"
app=$CI_PRIMARY_REPOSITORY_PATH/app
repo_git=(git -C "$CI_PRIMARY_REPOSITORY_PATH")
if [[ $("${repo_git[@]}" rev-parse --is-shallow-repository) == true ]]; then
    "${repo_git[@]}" fetch --quiet --unshallow --tags
else
    "${repo_git[@]}" fetch --quiet --tags
fi
version_tag=$("${repo_git[@]}" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD)
version=${version_tag#v}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "error: the newest v-tag, $version_tag, is not vX.Y.Z" >&2; exit 1; }
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:)[[:space:]]+.+$/\1 $version/" "$app/project.yml"
grep -q "MARKETING_VERSION: $version\$" "$app/project.yml"
echo "version: PRHub $version ($version_tag)"
if [[ -n $release_build ]]; then
    number=${CI_BUILD_NUMBER:?}
    if [[ $number != "$release_build" ]]; then
        echo "warning: the commit says build $release_build; Xcode Cloud numbers this build $number, which TestFlight shows"
    fi
    sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:)[[:space:]]+[0-9]+$/\1 $number/" "$app/project.yml"
    grep -q "CURRENT_PROJECT_VERSION: $number\$" "$app/project.yml"
    echo "release: PRHub build $number — $release_notes"
fi
echo "workflow: ${CI_WORKFLOW_ID:-no id} (${CI_WORKFLOW:-no name})"
# An Internal - TestFlight build compares itself with the Internal group's newest build for Update available
# (PRHubUpdate); every other build with the Public group's.
if [[ ${CI_WORKFLOW_ID:-} == "$internal_workflow" ]]; then
    print 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) PRHUB_INTERNAL_TESTFLIGHT' >> "$app/Config/PRHub.xcconfig"
    echo "internal: built for the Internal TestFlight group"
fi
if [[ ${CI_WORKFLOW_ID:-} == "$tests_workflow" || ( -z ${CI_WORKFLOW_ID:-} && -z $release_build ) ]]; then
    (cd "$CI_PRIMARY_REPOSITORY_PATH" && swift test)
fi
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install --quiet xcodegen
cd "$app"
xcodegen generate --spec project.yml
resolved=PRHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$resolved"
cp Package.resolved "$resolved/Package.resolved"
