#!/bin/zsh
# Ships PRHub (app/, bundle com.jaigovindani.prreview, App Store Connect app 6831601628) to TestFlight from main.
# A release is a commit on main whose subject is `chore(release): PRHub build N — <What to Test>` and that sets
# CURRENT_PROJECT_VERSION in app/project.yml to N, with N from release/next-build.sh. Push it, then run:
#   release/ship.sh [--local] [--dry-run] ["<What to Test>"]
#
# Xcode Cloud: when App Store Connect has an Xcode Cloud product for PRHub with an enabled PRHub Release workflow
# (release/xcode-cloud.swift), that workflow builds the release (app/ci_scripts) and hands it to TestFlight with the
# subject's What to Test, and ship.sh follows it: it finds Xcode Cloud's build of the release, waits for it and for
# TestFlight to process it. TestFlight's number is Xcode Cloud's; it is N when next-build.sh chose N. A What to Test
# argument is not used: the commit's subject is the What to Test.
# Local: with no Xcode Cloud workflow, or with --local, it archives the release on this Mac with N, signs and checks the
# IPA for production APNs, uploads, sets What to Test and waits for the build to be VALID. With no release waiting to
# ship, a What to Test argument ships HEAD with N from next-build.sh and no release commit, as PRHub shipped before
# Xcode Cloud. Signing needs a login session: run it in one, not from a bare SSH shell.
#
# Then, either way, it adds the build to the TestFlight group PRHUB_TESTFLIGHT_GROUP (the public link's) and submits it
# for Beta App Review unless it is already submitted or an earlier build is still waiting for or in review (Apple
# reviews one at a time; submit the later one once that is approved:
# `swift release/testflight.swift <key> submit <version> <build>`). With PRHUB_SUBMIT=NO it does not submit, though
# Xcode Cloud's TestFlight External Testing post-action may.
# --dry-run does every check, says which way it would ship, and stops before it archives, uploads or waits.
# Prints `SHIPPED PRHub build <n>` or `SHIP FAILED: …`.
#
# Needs, in the environment: ASC_KEY_PATH (an App Store Connect API key, .p8, with the App Manager role), ASC_KEY_ID,
# ASC_ISSUER_ID and PRHUB_TESTFLIGHT_GROUP; and, to ship locally, a Mac whose Xcode can sign for the team in
# project.yml. Keep the key file in place until the script ends: xcodebuild reads it again during the upload.
set -uo pipefail
cd "${0:A:h}/.."
usage='usage: release/ship.sh [--local] [--dry-run] ["<What to Test>"]'
local_ship=0 dry_run=0 notes=
for argument in "$@"; do
    case $argument in
        --local) local_ship=1 ;;
        --dry-run) dry_run=1 ;;
        -*) echo "$usage"; exit 2 ;;
        *) [[ -z $notes ]] || { echo "$usage"; exit 2; }; notes=$argument ;;
    esac
done
for name in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID PRHUB_TESTFLIGHT_GROUP; do
    [[ -n ${(P)name:-} ]] || { echo "SHIP FAILED: $name is not set"; exit 1; }
done
[[ -s $ASC_KEY_PATH ]] || { echo "SHIP FAILED: no key at ASC_KEY_PATH"; exit 1; }
export ASC_KEY_PATH=${ASC_KEY_PATH:A}
key=$ASC_KEY_PATH
git pull -q --ff-only origin main || { echo "SHIP FAILED: main has moved on; rebase and push first"; exit 1; }

cd app
team=$(awk '$1 == "DEVELOPMENT_TEAM:" {print $2; exit}' project.yml)
bundle=$(awk '$1 == "PRODUCT_BUNDLE_IDENTIFIER:" {print $2; exit}' project.yml)
asc=(env APP_BUNDLE_ID="$bundle" swift ../release/testflight.swift "$key")
cloud=(env APP_BUNDLE_ID="$bundle" swift ../release/xcode-cloud.swift "$key" runs)

# The release is the newest change to app/project.yml, as Xcode Cloud's ci_scripts/release.sh reads it.
release=$(git log -1 --format=%H -- project.yml)
release_build=$(git show "${release}:app/project.yml" | awk '$1 == "CURRENT_PROJECT_VERSION:" {print $2; exit}')
prefix="chore(release): PRHub build $release_build — "
subject=$(git log -1 --format=%s "$release")
release_notes=
[[ $subject == "$prefix"* ]] && release_notes=${subject#"$prefix"}
git merge-base --is-ancestor "$release" origin/main \
    || { echo "SHIP FAILED: $(git log -1 --format=%h "$release") is not pushed to main"; exit 1; }
# The version, as app/ci_scripts/ci_post_clone.sh sets it: the newest vX.Y.Z tag reachable from the commit built.
version_of() {
    local tag
    tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$1" 2>/dev/null) || return 1
    print -r -- "${tag#v}"
}

if (( ! local_ship )); then
    why=$("${cloud[@]}" 2>&1 >/dev/null)
    case $? in
        0) ;;
        3) echo "No Xcode Cloud for PRHub ($why): shipping locally"; local_ship=1 ;;
        *) echo "SHIP FAILED: cannot read Xcode Cloud's builds: $why"; exit 1 ;;
    esac
fi

if (( local_ship )); then
    version=$(version_of HEAD) || { echo "SHIP FAILED: no vX.Y.Z tag reachable from HEAD"; exit 1; }
    if [[ -n $release_notes && -z $("${asc[@]}" state "$version" "$release_build") ]]; then
        build=$release_build
        [[ -n $notes ]] && echo "What to Test comes from the release commit, not the argument"
        notes=$release_notes
    elif [[ -n $notes ]]; then
        build=$(../release/next-build.sh) || { echo "SHIP FAILED: cannot pick the next build number"; exit 1; }
    else
        echo "SHIP FAILED: no release to ship. Push a 'chore(release): PRHub build N — …' commit with N" \
            "from release/next-build.sh, or pass What to Test"
        exit 1
    fi
    state=$("${asc[@]}" state "$version" "$build") || { echo "SHIP FAILED: cannot read TestFlight's builds"; exit 1; }
    [[ -z $state ]] || { echo "SHIP FAILED: TestFlight already has build $build ($state)"; exit 1; }
    echo "PRHub $version build $build from $(git rev-parse --short HEAD): $notes"
    (( dry_run )) && { echo "DRY RUN: would archive build $build here, upload it and submit it"; exit 0; }

    archive=build/PRHub.xcarchive
    ipa=build/ipa
    auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    mkdir -p build
    rm -rf "$archive" "$ipa"
    xcodegen generate --spec project.yml --quiet || { echo "SHIP FAILED: xcodegen"; exit 1; }
    xcodebuild archive -project PRHub.xcodeproj -scheme PRHub -configuration Release \
        -destination 'generic/platform=iOS' -archivePath "$archive" -derivedDataPath build/DerivedData-release \
        -allowProvisioningUpdates "${auth[@]}" CURRENT_PROJECT_VERSION="$build" MARKETING_VERSION="$version" 2>&1 | grep -E ' error:|\*\* ARCHIVE' | tail -5
    [[ ${pipestatus[1]} == 0 ]] || { echo "SHIP FAILED: archive of PRHub build $build"; exit 1; }

    export_with() {
        local options=build/ExportOptions-$1.plist
        /bin/cp ../release/ExportOptions.plist "$options"
        /usr/libexec/PlistBuddy -c "Add :teamID string $team" "$options"
        /usr/libexec/PlistBuddy -c "Set :destination $1" "$options"
        xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$ipa" \
            -allowProvisioningUpdates "${auth[@]}" 2>&1 | grep -v 'PRIVATE KEY' | grep -E 'error:|EXPORT|Exported|Uploaded' | tail -6
        return ${pipestatus[1]}
    }
    export_with export || { echo "SHIP FAILED: export of PRHub build $build"; exit 1; }
    check=build/ipa-check
    rm -rf "$check" && mkdir -p "$check" && unzip -q -o "$ipa"/*.ipa -d "$check"
    aps=$(codesign -d --entitlements :- "$check"/Payload/*.app 2>/dev/null | plutil -extract aps-environment raw -o - -)
    [[ $aps == production ]] || { echo "SHIP FAILED: aps-environment is '$aps', not production"; exit 1; }
    export_with upload || { echo "SHIP FAILED: upload of PRHub build $build"; exit 1; }
    "${asc[@]}" what-to-test "$version" "$build" "$notes" || { echo "SHIP FAILED: What to Test of build $build"; exit 1; }
else
    [[ -n $release_notes ]] || {
        echo "SHIP FAILED: Xcode Cloud ships a release commit, and the newest change to app/project.yml is '$subject'." \
            "Push a 'chore(release): PRHub build N — …' commit with N from release/next-build.sh, then run release/ship.sh"
        exit 1
    }
    [[ -n $notes && $notes != "$release_notes" ]] && echo "What to Test comes from the release commit, not the argument"
    version=$(version_of "$release") || { echo "SHIP FAILED: no vX.Y.Z tag reachable from the release commit"; exit 1; }
    echo "PRHub $version build $release_build: $release_notes"
    (( dry_run )) && { echo "DRY RUN: would follow Xcode Cloud's build of build $release_build and submit it"; exit 0; }

    seen=
    started=$SECONDS
    while true; do
        git fetch -q origin main
        run=
        # Newest first; Xcode Cloud builds the head of the push, which is the release or a commit after it.
        for line in "${(@f)$("${cloud[@]}")}"; do
            if [[ -n $line ]] && git merge-base --is-ancestor "$release" "${line%% *}" 2>/dev/null; then
                run=$line
                break
            fi
        done
        if [[ -z $run ]]; then
            if (( SECONDS - started > 600 )); then
                echo "SHIP FAILED: Xcode Cloud started no build of build $release_build in 10 minutes" \
                    "(App Store Connect → PRHub → Xcode Cloud → PRHub Release)"
                exit 1
            fi
        else
            read -r _ build progress outcome <<< "$run"
            [[ $run != "$seen" ]] && echo "Xcode Cloud build $build: $progress $outcome"
            seen=$run
            if [[ $progress == COMPLETE ]]; then
                [[ $outcome == SUCCEEDED ]] || { echo "SHIP FAILED: Xcode Cloud build $build $outcome (App Store Connect → Xcode Cloud → Builds)"; exit 1; }
                break
            fi
            if (( SECONDS - started > 5400 )); then
                echo "SHIP FAILED: Xcode Cloud build $build has not finished in 90 minutes"
                exit 1
            fi
        fi
        sleep 30
    done
    [[ $build == "$release_build" ]] || echo "Xcode Cloud numbered it $build; the commit says $release_build"
fi

for _ in {1..60}; do
    state=$("${asc[@]}" state "$version" "$build" 2>/dev/null)
    [[ $state == VALID ]] && break
    [[ $state == FAILED || $state == INVALID ]] && { echo "SHIP FAILED: PRHub build $build is $state"; exit 1; }
    sleep 30
done
[[ $state == VALID ]] || { echo "SHIP FAILED: PRHub build $build is still ${state:-missing} after 30 minutes"; exit 1; }
"${asc[@]}" add-to-group "$version" "$build" "$PRHUB_TESTFLIGHT_GROUP" \
    || { echo "SHIP FAILED: adding build $build to the TestFlight group"; exit 1; }
if [[ ${PRHUB_SUBMIT:-YES} == NO ]]; then
    echo "build $build not submitted for Beta App Review: PRHUB_SUBMIT=NO"
else
    "${asc[@]}" submit "$version" "$build" || { echo "SHIP FAILED: Beta App Review submission of build $build"; exit 1; }
fi
echo "SHIPPED PRHub build $build"
