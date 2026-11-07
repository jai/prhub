#!/bin/zsh
# Ships PRHub (app/, bundle com.jaigovindani.prreview, App Store Connect app 6831601628) to TestFlight from main:
#   release/ship.sh "<What to Test>"
# It takes the next build number after App Store Connect's highest for PRHub, archives app/ with that number, signs and
# checks the IPA for production APNs, uploads, sets What to Test, waits for the build to be VALID, adds it to the
# TestFlight group PRHUB_TESTFLIGHT_GROUP (the public link's) and submits it for Beta App Review unless an earlier build
# is still waiting for or in review (Apple reviews one at a time; submit the later one once that is approved:
# `swift release/testflight.swift <key> submit <version> <build>`). Prints `SHIPPED PRHub build <n>` or `SHIP FAILED: …`.
#
# Needs, in the environment: ASC_KEY_PATH (an App Store Connect API key, .p8, with the App Manager role), ASC_KEY_ID,
# ASC_ISSUER_ID and PRHUB_TESTFLIGHT_GROUP; and a Mac whose Xcode can sign for the team in project.yml. Signing needs a
# login session: run it in one, not from a bare SSH shell.
set -uo pipefail
cd "${0:A:h}/.."
notes=${1:?usage: release/ship.sh "<What to Test>"}
for name in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID PRHUB_TESTFLIGHT_GROUP; do
    [[ -n ${(P)name:-} ]] || { echo "SHIP FAILED: $name is not set"; exit 1; }
done
[[ -s $ASC_KEY_PATH ]] || { echo "SHIP FAILED: no key at ASC_KEY_PATH"; exit 1; }
key=${ASC_KEY_PATH:A}
git pull -q --ff-only origin main || { echo "SHIP FAILED: main has moved on; rebase and push first"; exit 1; }

cd app
version=$(awk '$1 == "MARKETING_VERSION:" {print $2; exit}' project.yml)
team=$(awk '$1 == "DEVELOPMENT_TEAM:" {print $2; exit}' project.yml)
bundle=$(awk '$1 == "PRODUCT_BUNDLE_IDENTIFIER:" {print $2; exit}' project.yml)
asc=(env APP_BUNDLE_ID="$bundle" swift ../release/testflight.swift "$key")
latest=$("${asc[@]}" latest) || { echo "SHIP FAILED: App Store Connect did not list PRHub's builds"; exit 1; }
build=$((latest + 1))
echo "PRHub $version build $build from $(git rev-parse --short HEAD)"

archive=build/PRHub.xcarchive
ipa=build/ipa
auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
mkdir -p build
rm -rf "$archive" "$ipa"
xcodegen generate --spec project.yml --quiet || { echo "SHIP FAILED: xcodegen"; exit 1; }
xcodebuild archive -project PRHub.xcodeproj -scheme PRHub -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" -derivedDataPath build/DerivedData-release \
    -allowProvisioningUpdates "${auth[@]}" CURRENT_PROJECT_VERSION="$build" 2>&1 | grep -E ' error:|\*\* ARCHIVE' | tail -5
[[ ${pipestatus[1]} == 0 ]] || { echo "SHIP FAILED: archive of PRHub build $build"; exit 1; }

export_with() {
    local options=build/ExportOptions-$1.plist
    /bin/cp ../release/ExportOptions.plist "$options"
    /usr/libexec/PlistBuddy -c "Add :teamID string $team" "$options"
    /usr/libexec/PlistBuddy -c "Set :destination $1" "$options"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$ipa" \
        -allowProvisioningUpdates "${auth[@]}" 2>&1 | grep -vE 'AuthKey|BEGIN PRIVATE' | tail -3
    return ${pipestatus[1]}
}
export_with export || { echo "SHIP FAILED: export of PRHub build $build"; exit 1; }
check=build/ipa-check
rm -rf "$check" && mkdir -p "$check" && unzip -q -o "$ipa"/*.ipa -d "$check"
aps=$(codesign -d --entitlements :- "$check"/Payload/*.app 2>/dev/null | plutil -extract aps-environment raw -o - -)
[[ $aps == production ]] || { echo "SHIP FAILED: aps-environment is '$aps', not production"; exit 1; }
export_with upload || { echo "SHIP FAILED: upload of PRHub build $build"; exit 1; }

"${asc[@]}" what-to-test "$version" "$build" "$notes" || { echo "SHIP FAILED: What to Test of build $build"; exit 1; }
for _ in {1..60}; do
    state=$("${asc[@]}" state "$version" "$build" 2>/dev/null)
    [[ $state == VALID ]] && break
    [[ $state == FAILED || $state == INVALID ]] && { echo "SHIP FAILED: PRHub build $build is $state"; exit 1; }
    sleep 30
done
[[ $state == VALID ]] || { echo "SHIP FAILED: PRHub build $build is still ${state:-missing} after 30 minutes"; exit 1; }
"${asc[@]}" add-to-group "$version" "$build" "$PRHUB_TESTFLIGHT_GROUP" \
    || { echo "SHIP FAILED: adding build $build to the TestFlight group"; exit 1; }
"${asc[@]}" submit "$version" "$build" || { echo "SHIP FAILED: Beta App Review submission of build $build"; exit 1; }
echo "SHIPPED PRHub build $build"
