#!/usr/bin/env bash
# newest-kits.sh — the hourly release's first step (#54, "always latest"): resolves AgentChatKit, FeedbackKit and
# DurableNetworking to the newest versions Package.swift's `from:` ranges allow, makes app/Package.resolved (what CI and Xcode Cloud build) agree with
# the root one (PRKit) for every package they share, and, when either changed, commits both to main through GitHub's
# API (so the commit is signed) for the release's tests to run on. Prints `changed=` and `kits=` to GITHUB_OUTPUT.
#
#   GH_TOKEN=… scripts/newest-kits.sh            (in CI; GITHUB_REPOSITORY and GITHUB_OUTPUT from Actions)
#   scripts/newest-kits.sh --local               resolves and syncs the files here, commits nothing
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Every kit: each blocks API breaks in its own CI (Jai: always latest, never breaking).
swift package update agentchatkit feedbackkit durable-networking >/dev/null
python3 - <<'PY'
import json
root = {p["identity"]: p for p in json.load(open("Package.resolved"))["pins"]}
path = "app/Package.resolved"
text = open(path).read()
for pin in json.loads(text)["pins"]:
    new = root.get(pin["identity"])
    if not new or new["state"] == pin["state"]:
        continue
    # Only this pin's state changes, in place, so the file keeps Xcode's formatting.
    start = text.index('"identity" : "%s"' % pin["identity"])
    end = text.index("}", text.index('"state"', start))
    block = text[start:end]
    for key in ("revision", "version"):
        if key in pin["state"] and key in new["state"]:
            block = block.replace('"%s"' % pin["state"][key], '"%s"' % new["state"][key])
    text = text[:start] + block + text[end:]
open(path, "w").write(text)
PY

kits=$(python3 - <<'PY'
import json
pins = json.load(open("Package.resolved"))["pins"]
print(", ".join(p["identity"] + " " + str(p["state"].get("version")) for p in pins))
PY
)
if git diff --quiet -- Package.resolved app/Package.resolved; then
  echo "the kits are the newest already: $kits"
  [ -n "${GITHUB_OUTPUT:-}" ] && { echo "changed=false"; echo "kits=$kits"; } >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "newest: $kits"
[ "${1:-}" = "--local" ] && exit 0

# One signed commit on main's head, through the API: blobs, a tree on the head's, the commit, the ref moved.
repo="$GITHUB_REPOSITORY"
head=$(git rev-parse HEAD)
tree=$(gh api "repos/$repo/git/commits/$head" -q .tree.sha)
entries=()
for file in Package.resolved app/Package.resolved; do
  blob=$(gh api "repos/$repo/git/blobs" -f encoding=base64 -f content="$(base64 < "$file" | tr -d '\n')" -q .sha)
  entries+=(-f "tree[][path]=$file" -f "tree[][mode]=100644" -f "tree[][type]=blob" -f "tree[][sha]=$blob")
done
new_tree=$(gh api "repos/$repo/git/trees" -f base_tree="$tree" "${entries[@]}" -q .sha)
message="fix(deps): newest kits: $kits

The hourly release resolved Package.swift's ranges to the newest versions (#54); the
release's tests run on this commit."
commit=$(gh api "repos/$repo/git/commits" -f message="$message" -f tree="$new_tree" -f "parents[]=$head" -q .sha)
gh api -X PATCH "repos/$repo/git/refs/heads/main" -f sha="$commit" -F force=false > /dev/null
echo "committed ${commit:0:7} on main"
{ echo "changed=true"; echo "kits=$kits"; } >> "$GITHUB_OUTPUT"
