#!/bin/zsh
# Sourced by ci_post_clone.sh and ci_post_xcodebuild.sh. The PRHub Release workflow starts on a vX.Y.Z tag, which
# release-please makes for each release (AGENTS.md, "Releases"). There this sets `release_version` to X.Y.Z and
# `release_notes` to that version's What to Test from CHANGELOG.md (release/what-to-test.sh), after checking that
# MARKETING_VERSION in app/project.yml is X.Y.Z: a build of anything else fails here instead of shipping. Other
# workflows skip the check and get empty values.
repo=${CI_PRIMARY_REPOSITORY_PATH:?not running in Xcode Cloud}
release_version=
release_notes=
if [[ ${CI_WORKFLOW:-} != "PRHub Release" ]]; then
    return 0
fi
tag=${CI_TAG:-}
if [[ ! $tag =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "error: not a release. PRHub Release builds a vX.Y.Z tag, and this build's tag is '${tag:-none}'." \
        "Its start condition must be Tag Changes on tags starting with v." >&2
    return 1
fi
marketing=$(awk '$1 == "MARKETING_VERSION:" {print $2; exit}' "$repo/app/project.yml")
if [[ $marketing != "${tag#v}" ]]; then
    echo "error: $tag sets MARKETING_VERSION to '$marketing', not ${tag#v}: it is not a release-please release" >&2
    return 1
fi
release_notes=$("$repo/release/what-to-test.sh" "${tag#v}") || return 1
release_version=${tag#v}
