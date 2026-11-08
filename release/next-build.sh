#!/bin/zsh
# Prints N for the next `chore(release): PRHub build N — <What to Test>` commit: one more than the highest of
# origin/main's CURRENT_PROJECT_VERSION, TestFlight's highest PRHub build and Xcode Cloud's newest build number.
# Xcode Cloud numbers every build of its product, failed ones and other apps' workflows included, and TestFlight shows
# its number (app/ci_scripts/ci_post_clone.sh), so N from here keeps the commit and TestFlight on the same number.
# Needs ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID in the environment, as release/ship.sh does. Run:
#   release/next-build.sh
set -euo pipefail
cd "${0:A:h}/.."
for name in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
    [[ -n ${(P)name:-} ]] || { echo "$name is not set" >&2; exit 1; }
done
git fetch -q origin main
main=$(git show origin/main:app/project.yml | awk '$1 == "CURRENT_PROJECT_VERSION:" {print $2; exit}')
bundle=$(awk '$1 == "PRODUCT_BUNDLE_IDENTIFIER:" {print $2; exit}' app/project.yml)
testflight=$(APP_BUNDLE_ID=$bundle swift release/testflight.swift "${ASC_KEY_PATH:A}" latest)
# Exit 3 is no Xcode Cloud product: no Xcode Cloud numbers to stay past.
cloud=$(APP_BUNDLE_ID=$bundle swift release/xcode-cloud.swift "${ASC_KEY_PATH:A}" latest) || (( $? == 3 ))
highest=$(printf '%s\n' "$main" "$testflight" "${cloud:-0}" | sort -n | tail -1)
echo $(( highest + 1 ))
