#!/bin/zsh
# Xcode Cloud, after the clone. Only what the build cannot do without:
# - The project is generated (*.xcodeproj is gitignored): XcodeGen makes app/PRHub.xcodeproj, and app/Package.resolved
#   goes into it, because Xcode Cloud resolves packages only from a Package.resolved.
# - The version is the release tag that started the build (CI_TAG, vX.Y.Z); the build number is Xcode Cloud's.
set -euo pipefail
app=$CI_PRIMARY_REPOSITORY_PATH/app
version=${CI_TAG:?the build must start from a vX.Y.Z tag}
version=${version#v}
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:).*/\1 $version/" "$app/project.yml"
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\1 ${CI_BUILD_NUMBER:?}/" "$app/project.yml"
echo "PRHub $version ($CI_BUILD_NUMBER)"
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install --quiet xcodegen
cd "$app"
xcodegen generate --spec project.yml
mkdir -p PRHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved PRHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
