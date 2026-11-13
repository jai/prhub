// PRHub's version, from the conventional commits on main since the newest vX.Y.Z tag. release/cadence.mjs plans it
// before each Internal TestFlight build, tags main's head and makes the tag's GitHub Release; app/ci_scripts then
// build the app as the newest tag reachable from the build's commit (MARKETING_VERSION), and an Internal build at a
// tag gets the tag's notes as What to Test. Below 1.0.0 a feat or a breaking change bumps the minor and a fix or perf
// the patch; from 1.0.0 a breaking change bumps the major. Commits of no other type keep the version and make no tag.

const TAG = /^v(\d+)\.(\d+)\.(\d+)$/;
const CONVENTIONAL = /^(\w+)(?:\([^)]*\))?(!)?:\s*\S/;
const BREAKING_FOOTER = /^BREAKING[ -]CHANGE:/m;
const LEVELS = ["patch", "minor", "major"];

function parse(tag) {
  const match = TAG.exec(tag);
  return match ? match.slice(1, 4).map(Number) : null;
}

/** The highest `vX.Y.Z` among `tags`, or null. Other tags are ignored. */
export function newestTag(tags) {
  const compare = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];
  let newest = null;
  for (const tag of tags) {
    const version = parse(tag);
    if (version && (!newest || compare(version, parse(newest)) > 0)) newest = tag;
  }
  return newest;
}

/** A commit's conventional type (lowercased, or null) and whether it is breaking: `{ subject, body }` from git. */
export function classify({ subject, body = "" }) {
  const match = CONVENTIONAL.exec(subject);
  return { type: match ? match[1].toLowerCase() : null, breaking: Boolean(match?.[2]) || BREAKING_FOOTER.test(body) };
}

/** The bump the commits call for at `version` ([major, minor, patch]): "major", "minor", "patch" or null. */
export function bumpOf(version, commits) {
  let level = -1;
  for (const commit of commits) {
    const { type, breaking } = classify(commit);
    if (breaking) level = Math.max(level, version[0] >= 1 ? 2 : 1);
    else if (type === "feat") level = Math.max(level, 1);
    else if (type === "fix" || type === "perf") level = Math.max(level, 0);
  }
  return LEVELS[level] ?? null;
}

function bumped([major, minor, patch], level) {
  if (level === "major") return `${major + 1}.0.0`;
  if (level === "minor") return `${major}.${minor + 1}.0`;
  return `${major}.${minor}.${patch + 1}`;
}

/** What a version brings: one `- <subject>` line per feat or breaking commit, then per fix or perf, newest first. */
export function notesFor(commits) {
  const listed = commits.map((commit) => ({ ...classify(commit), subject: commit.subject }));
  const features = listed.filter(({ type, breaking }) => breaking || type === "feat");
  const fixes = listed.filter(({ type, breaking }) => !breaking && (type === "fix" || type === "perf"));
  return [...features, ...fixes].map(({ subject }) => `- ${subject}`).join("\n");
}

/**
 * The version of a build of `head`, from `tags` (the v-tags reachable from it), `headTags` (those on it) and
 * `commitsSince(tag | null)` (the commits after that tag up to the head, as `{ subject, body }`).
 * Returns `{ action: "reuse" | "keep" | "tag", tag, version, notes? }`: reuse the head's own tag; keep the newest tag's
 * version, with no new tag; or tag the head with a new version and its notes.
 */
export function planVersion({ tags, headTags, commitsSince }) {
  const own = newestTag(headTags);
  if (own) return { action: "reuse", tag: own, version: own.slice(1) };
  const base = newestTag(tags);
  const current = base ? parse(base) : [0, 0, 0];
  const commits = commitsSince(base);
  const level = bumpOf(current, commits);
  if (!level) return { action: "keep", tag: base, version: current.join(".") };
  const version = bumped(current, level);
  return { action: "tag", tag: `v${version}`, version, notes: notesFor(commits) };
}

/** Makes `tag`'s GitHub Release with `notes` unless it has one. Returns "exists" or "created". */
export async function ensureRelease(github, tag, notes) {
  if (await github("GET", `releases/tags/${encodeURIComponent(tag)}`)) return "exists";
  await github("POST", "releases", { tag_name: tag, name: tag, body: notes });
  return "created";
}

/**
 * Carries out a plan on GitHub (`github` as release/cadence.mjs's githubClient): a new version gets an annotated tag
 * on `head` whose message is its notes, then a Release; a reused tag gets its Release if it has none, with
 * `tagMessage(tag)` as notes. Returns a short description for the log.
 */
export async function publishVersion(github, plan, head, tagMessage) {
  if (plan.action === "keep") return `version ${plan.version} (no feat or fix since ${plan.tag ?? "the start"})`;
  if (plan.action === "reuse") {
    const release = await ensureRelease(github, plan.tag, tagMessage(plan.tag));
    return `version ${plan.version} (${plan.tag} on the head; release ${release})`;
  }
  const object = await github("POST", "git/tags", { tag: plan.tag, message: plan.notes, object: head, type: "commit" });
  await github("POST", "git/refs", { ref: `refs/tags/${plan.tag}`, sha: object.sha });
  await ensureRelease(github, plan.tag, plan.notes);
  return `version ${plan.version} (tagged ${plan.tag}, release created)`;
}
