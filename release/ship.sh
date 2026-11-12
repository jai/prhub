#!/bin/zsh
# Ships PRHub (app/, bundle com.jaigovindani.prreview, App Store Connect app 6831601628) to TestFlight from main.
# A release is a vX.Y.Z tag on main that release-please made: merging its release PR sets MARKETING_VERSION in
# app/project.yml to X.Y.Z, adds the version's section to CHANGELOG.md, and tags and publishes the GitHub Release. That
# section is the build's What to Test (release/what-to-test.sh). Once the tag is on GitHub, run:
#   release/ship.sh [--local] [--dry-run] ["<What to Test>"]
#
# Xcode Cloud: when App Store Connect has an Xcode Cloud product for PRHub with an enabled PRHub Release workflow
# (release/xcode-cloud.swift), that workflow starts on the tag, builds it (app/ci_scripts) and hands it to TestFlight
# with its What to Test, and ship.sh follows it: it finds Xcode Cloud's build of the newest release, waits for it and
# for TestFlight to process it. TestFlight's number is Xcode Cloud's. A What to Test argument is not used.
# Local: with no Xcode Cloud workflow, or with --local, it ships the newest release when TestFlight has no build of its
# version yet. It archives the tag's tree on this Mac with the build number from release/next-build.sh, signs and
# checks the IPA for production APNs, uploads, sets What to Test and waits for the build to be VALID. With no release
# waiting to ship, a What to Test argument ships HEAD at app/project.yml's version with the next build number, and
# makes no release. Signing needs a login session: run it in one, not from a bare SSH shell.
#
# Then, either way, it adds the build to the TestFlight group PRHUB_TESTFLIGHT_GROUP (the public link's) and submits it
# for Beta App Review unless it is already submitted or an earlier build is still waiting for or in review (Apple
# reviews one at a time; submit the later one once that is approved:
# `swift release/testflight.swift <key> submit <version> <build>`). With PRHUB_SUBMIT=NO it does not submit, though
# Xcode Cloud's TestFlight External Testing post-action may.
# --dry-run does every check, says which way it would ship, and stops before it archives, uploads or waits.
# Prints `SHIPPED PRHub <version> build <n>` or `SHIP FAILED: …`.
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
git fetch -q --tags origin || { echo "SHIP FAILED: cannot fetch tags"; exit 1; }

cd app
marketing() { awk '$1 == "MARKETING_VERSION:" {print $2; exit}'; }
team=$(awk '$1 == "DEVELOPMENT_TEAM:" {print $2; exit}' project.yml)
bundle=$(awk '$1 == "PRODUCT_BUNDLE_IDENTIFIER:" {print $2; exit}' project.yml)
asc=(env APP_BUNDLE_ID="$bundle" swift ../release/testflight.swift "$key")
cloud=(env APP_BUNDLE_ID="$bundle" swift ../release/xcode-cloud.swift "$key" runs)

# The release is the newest vX.Y.Z tag on main whose app/project.yml sets MARKETING_VERSION to X.Y.Z, as Xcode Cloud's
# ci_scripts/release.sh checks. PRKit's tags from before release-please set no such version and are not releases.
tag=$(git tag --merged origin/main --sort=-v:refname --list 'v[0-9]*.[0-9]*.[0-9]*' | head -1)
release_version= release_notes=
if [[ -n $tag && $(git show "${tag}:app/project.yml" | marketing) == "${tag#v}" ]]; then
    release_version=${tag#v}
    release_notes=$(../release/what-to-test.sh "$release_version") || { echo "SHIP FAILED: no What to Test for $tag"; exit 1; }
fi

if (( ! local_ship )); then
    why=$("${cloud[@]}" 2>&1 >/dev/null)
    case $? in
        0) ;;
        3) echo "No Xcode Cloud for PRHub ($why): shipping locally"; local_ship=1 ;;
        *) echo "SHIP FAILED: cannot read Xcode Cloud's builds: $why"; exit 1 ;;
    esac
fi

if (( local_ship )); then
    shipped=
    if [[ -n $release_version ]]; then
        shipped=$("${asc[@]}" builds "$release_version") || { echo "SHIP FAILED: cannot read TestFlight's builds"; exit 1; }
    fi
    if [[ -n $release_version && -z $shipped ]]; then
        version=$release_version
        ref=$tag
        [[ -n $notes ]] && echo "What to Test comes from CHANGELOG.md, not the argument"
        notes=$release_notes
    elif [[ -n $notes ]]; then
        version=$(marketing < project.yml)
        ref=HEAD
    else
        if [[ -n $shipped ]]; then
            echo "SHIP FAILED: no release to ship: TestFlight has PRHub $release_version ($tag) already." \
                "Merge release-please's release PR, or pass What to Test"
        else
            echo "SHIP FAILED: no release to ship: main has no release tag. Merge release-please's release PR," \
                "or pass What to Test"
        fi
        exit 1
    fi
    build=$(../release/next-build.sh) || { echo "SHIP FAILED: cannot pick the next build number"; exit 1; }
    state=$("${asc[@]}" state "$version" "$build") || { echo "SHIP FAILED: cannot read TestFlight's builds"; exit 1; }
    [[ -z $state ]] || { echo "SHIP FAILED: TestFlight already has build $build ($state)"; exit 1; }
    echo "PRHub $version build $build from $ref ($(git rev-parse --short "$ref")): $notes"
    (( dry_run )) && { echo "DRY RUN: would archive build $build here, upload it and submit it"; exit 0; }

    # The release's own tree: main may have moved on past the tag.
    tree=build/source
    rm -rf "$tree" && mkdir -p "$tree" && git -C .. archive "$ref" | tar -x -C "$tree" \
        || { echo "SHIP FAILED: cannot extract $ref"; exit 1; }
    archive=build/PRHub.xcarchive
    ipa=build/ipa
    auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    mkdir -p build
    rm -rf "$archive" "$ipa"
    xcodegen generate --spec "$tree/app/project.yml" --quiet || { echo "SHIP FAILED: xcodegen"; exit 1; }
    xcodebuild archive -project "$tree/app/PRHub.xcodeproj" -scheme PRHub -configuration Release \
        -destination 'generic/platform=iOS' -archivePath "$archive" -derivedDataPath build/DerivedData-release \
        -allowProvisioningUpdates "${auth[@]}" CURRENT_PROJECT_VERSION="$build" 2>&1 | grep -E ' error:|\*\* ARCHIVE' | tail -5
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
    [[ -n $release_version ]] || {
        echo "SHIP FAILED: Xcode Cloud ships a release tag, and main has none (newest vX.Y.Z tag: ${tag:-none})." \
            "Merge release-please's release PR, then run release/ship.sh"
        exit 1
    }
    [[ -n $notes && $notes != "$release_notes" ]] && echo "What to Test comes from CHANGELOG.md, not the argument"
    version=$release_version
    release=$(git rev-list -n 1 "$tag")
    echo "PRHub $version from $tag: $release_notes"
    (( dry_run )) && { echo "DRY RUN: would follow Xcode Cloud's build of $tag and submit it"; exit 0; }

    seen=
    started=$SECONDS
    while true; do
        git fetch -q origin main
        run=
        # Newest first; Xcode Cloud builds the tag's commit.
        for line in "${(@f)$("${cloud[@]}")}"; do
            if [[ -n $line ]] && git merge-base --is-ancestor "$release" "${line%% *}" 2>/dev/null; then
                run=$line
                break
            fi
        done
        if [[ -z $run ]]; then
            if (( SECONDS - started > 600 )); then
                echo "SHIP FAILED: Xcode Cloud started no build of $tag in 10 minutes" \
                    "(App Store Connect → PRHub → Xcode Cloud → PRHub Release)"
                exit 1
            fi
        else
            read -r _ build progress status <<< "$run"
            [[ $run != "$seen" ]] && echo "Xcode Cloud build $build: $progress $status"
            seen=$run
            if [[ $progress == COMPLETE ]]; then
                [[ $status == SUCCEEDED ]] || { echo "SHIP FAILED: Xcode Cloud build $build $status (App Store Connect → Xcode Cloud → Builds)"; exit 1; }
                break
            fi
            if (( SECONDS - started > 5400 )); then
                echo "SHIP FAILED: Xcode Cloud build $build has not finished in 90 minutes"
                exit 1
            fi
        fi
        sleep 30
    done
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
echo "SHIPPED PRHub $version build $build"
