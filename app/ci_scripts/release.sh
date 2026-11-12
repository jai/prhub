#!/bin/zsh
# Sourced by ci_post_clone.sh and ci_post_xcodebuild.sh. Sets `release_build` and `release_notes` from the newest commit
# that changed app/project.yml, which must be `chore(release): PRHub build N — <What to Test>` with N its
# CURRENT_PROJECT_VERSION: the PRHub Release workflow starts only when app/project.yml changes on main, and a change
# there that is not a release fails here instead of shipping. Other workflows skip the check and get empty values. The
# workflow is known by its id (workflows.sh), which a rename leaves alone.
repo=${CI_PRIMARY_REPOSITORY_PATH:?not running in Xcode Cloud}
source "${0:A:h}/workflows.sh"
release_build=
release_notes=
if [[ ${CI_WORKFLOW_ID:-} != "$release_workflow" ]]; then
    return 0
fi
if [[ $(git -C "$repo" rev-parse --is-shallow-repository) == true ]]; then
    git -C "$repo" fetch --quiet --deepen 200
fi
commit=$(git -C "$repo" log -1 --format=%H -- app/project.yml)
subject=$(git -C "$repo" log -1 --format=%s "$commit")
# From the commit, not the working copy: ci_post_clone.sh rewrites the number there.
build=$(git -C "$repo" show "${commit}:app/project.yml" | awk '$1 == "CURRENT_PROJECT_VERSION:" {print $2; exit}')
prefix="chore(release): PRHub build $build — "
if [[ $subject != "$prefix"* ]]; then
    echo "error: not a release. The newest change to app/project.yml ($commit) is '$subject', not '$prefix…'." \
        "Release builds start from a 'chore(release): PRHub build N — …' commit that sets CURRENT_PROJECT_VERSION to N." >&2
    return 1
fi
release_build=$build
release_notes=${subject#"$prefix"}
