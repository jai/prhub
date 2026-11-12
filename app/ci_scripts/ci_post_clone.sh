#!/bin/zsh
# Xcode Cloud, after the clone, from app/ci_scripts. The project is generated (*.xcodeproj is gitignored), so this
# installs XcodeGen and generates app/PRHub.xcodeproj before Xcode Cloud opens it. In the PRHub Release workflow it
# first checks the commit is a release (release.sh) and sets CURRENT_PROJECT_VERSION to Xcode Cloud's build number,
# which is the number TestFlight shows. release/next-build.sh picks N so the two agree; when they do not, Xcode Cloud's
# number wins and this says so.
# Xcode Cloud resolves packages only from a Package.resolved, and the generated project has none: app/Package.resolved
# pins the remote ones (PostHog) and goes into the project here. Refresh it when project.yml's packages change:
# `xcodebuild -resolvePackageDependencies` in app/, then copy the project's Package.resolved back to app/.
set -euo pipefail
source "${0:A:h}/release.sh"
app=$CI_PRIMARY_REPOSITORY_PATH/app
if [[ -n $release_build ]]; then
    number=${CI_BUILD_NUMBER:?}
    if [[ $number != "$release_build" ]]; then
        echo "warning: the commit says build $release_build; Xcode Cloud numbers this build $number, which TestFlight shows"
    fi
    sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:)[[:space:]]+[0-9]+$/\1 $number/" "$app/project.yml"
    grep -q "CURRENT_PROJECT_VERSION: $number\$" "$app/project.yml"
    echo "release: PRHub build $number — $release_notes"
fi
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install --quiet xcodegen
cd "$app"
xcodegen generate --spec project.yml
resolved=PRHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$resolved"
cp Package.resolved "$resolved/Package.resolved"
