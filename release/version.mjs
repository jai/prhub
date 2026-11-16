// PRHub's version, from the conventional commits on main since the newest vX.Y.Z tag. The hourly release
// (.github/workflows/hourly-release.yml) runs it twice around the full tests:
//   node release/version.mjs plan             whether main's head is due a new version; to GITHUB_OUTPUT, sha= and tag=
//   node release/version.mjs publish <sha>    after the tests of <sha> passed: its annotated tag and GitHub Release
// The vX.Y.Z tag starts Xcode Cloud's tag-started workflow, which builds that commit for TestFlight. app/ci_scripts
// build the app as the newest tag reachable from the commit (MARKETING_VERSION) and use the tag's notes as What to Test.
// Below 1.0.0 a feat or a breaking change bumps the minor and a fix or perf the patch; from 1.0.0 a breaking change
// bumps the major. Commits of no other type keep the version and make no tag.
// publish needs GITHUB_TOKEN (contents: write; the jai-agents App's token, to tag a commit that changes
// .github/workflows) and GITHUB_REPOSITORY. Exits non-zero only when git or the API fails.
import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

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

/**
 * A tag's message without the signature git keeps at its end when the tag was signed by hand (`git tag -s`): SSH or
 * PGP. Notes are for people; `app/ci_scripts/ci_post_xcodebuild.sh` cuts it the same way for What to Test.
 */
export function withoutSignature(message) {
  return message.replace(/(^|\n)-----BEGIN [A-Z ]*SIGNATURE-----\n[\s\S]*$/, "").trimEnd();
}

/** Makes `tag`'s GitHub Release with `notes` unless it has one. Returns "exists" or "created". */
export async function ensureRelease(github, tag, notes) {
  if (await github("GET", `releases/tags/${encodeURIComponent(tag)}`)) return "exists";
  await github("POST", "releases", { tag_name: tag, name: tag, body: notes });
  return "created";
}

/**
 * Carries out a plan on GitHub (`github` from githubClient): a new version gets an annotated tag
 * on `head` whose message is its notes, then a Release; a reused tag gets its Release if it has none, with
 * `tagMessage(tag)` as notes. Returns a short description for the log.
 */
export async function publishVersion(github, plan, head, tagMessage) {
  if (plan.action === "keep") return `version ${plan.version} (no feat or fix since ${plan.tag ?? "the start"})`;
  if (plan.action === "reuse") {
    const release = await ensureRelease(github, plan.tag, withoutSignature(tagMessage(plan.tag)));
    return `version ${plan.version} (${plan.tag} on the head; release ${release})`;
  }
  const object = await github("POST", "git/tags", { tag: plan.tag, message: plan.notes, object: head, type: "commit" });
  await github("POST", "git/refs", { ref: `refs/tags/${plan.tag}`, sha: object.sha });
  await ensureRelease(github, plan.tag, plan.notes);
  return `version ${plan.version} (tagged ${plan.tag}, release created)`;
}

/** A small GitHub REST client for `repository` (owner/name): `github(method, path, body?)` returns the JSON, or null on a 404. */
export function githubClient({ token, repository, fetchImpl = fetch }) {
  return async function github(method, path, body) {
    const response = await fetchImpl(`https://api.github.com/repos/${repository}/${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (response.status === 404) return null;
    const text = await response.text();
    if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status} ${text}`);
    return JSON.parse(text);
  };
}

const repoRoot = fileURLToPath(new URL("..", import.meta.url));

function git(...args) {
  return execFileSync("git", ["-C", repoRoot, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

const lines = (out) => (out ? out.split("\n") : []);

/** The commits in `range`, newest first, as `{ subject, body }`. */
function commitsInGit(range) {
  return git("log", "--format=%s%x1f%b%x1e", range)
    .split("\x1e")
    .map((record) => record.replace(/^\n/, ""))
    .filter(Boolean)
    .map((record) => {
      const [subject, body = ""] = record.split("\x1f");
      return { subject, body };
    });
}

function planAt(sha) {
  return planVersion({
    tags: lines(git("tag", "--merged", sha, "--list", "v*")),
    headTags: lines(git("tag", "--points-at", sha, "--list", "v*")),
    commitsSince: (tag) => commitsInGit(tag ? `${tag}..${sha}` : sha),
  });
}

const USAGE = "usage: node release/version.mjs plan | publish <sha>";

async function main() {
  const [mode, sha, ...rest] = process.argv.slice(2);
  if (!(mode === "plan" && !sha) && !(mode === "publish" && /^[0-9a-f]{40}$/.test(sha ?? "")) || rest.length) {
    console.error(USAGE);
    process.exit(2);
  }
  git("fetch", "--quiet", "--tags", "origin", "main");
  if (mode === "plan") {
    const head = git("rev-parse", "origin/main");
    const plan = planAt(head);
    console.log(plan.action === "tag"
      ? `release ${head.slice(0, 7)} as ${plan.tag}`
      : `nothing to release: ${head.slice(0, 7)} keeps ${plan.tag ?? "no version"} (${plan.action})`);
    if (plan.action === "tag" && process.env.GITHUB_OUTPUT) {
      appendFileSync(process.env.GITHUB_OUTPUT, `sha=${head}\ntag=${plan.tag}\n`);
    }
    return;
  }
  for (const name of ["GITHUB_TOKEN", "GITHUB_REPOSITORY"]) {
    if (!process.env[name]) {
      console.error(`${name} is not set`);
      process.exit(2);
    }
  }
  const github = githubClient({ token: process.env.GITHUB_TOKEN, repository: process.env.GITHUB_REPOSITORY });
  console.log(await publishVersion(github, planAt(sha), sha, (tag) => git("tag", "--list", "--format=%(contents)", tag)));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
