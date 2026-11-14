#!/usr/bin/env node
// PRHub's hourly release, in two steps around the tests, run once an hour by .github/workflows/hourly-release.yml:
//   node release/cadence.mjs decide [--dry-run]     whether main's head is due a release; to GITHUB_OUTPUT, sha=<head>
//   node release/cadence.mjs release <sha> [--dry-run]   after the full tests of <sha> passed: its version and builds
// No Xcode Cloud workflow starts on a push or a pull request; this is the only thing that starts them.
// decide: nothing while a build of Internal - TestFlight is pending or running, or when a scheduled hourly run already
// failed on main's head (a red commit is not retried; the next push is, or a run by hand). Otherwise the last released commit is that of
// Internal - TestFlight's newest run that SUCCEEDED (or, with none in the last 10, its newest run). Main's head is due
// when it differs from it and the commits between touch app/, PRKit/, Package.swift or DESIGN.md, unless a build of
// the head already succeeded or failed. Then the workflow runs the full tests (ios.yml) on that commit.
// release, once they pass:
//   1. points the branch ci/release at <sha>, so Xcode Cloud builds exactly the commit that was tested;
//   2. makes the version (release/version.mjs): a feat or fix since the newest vX.Y.Z tag tags <sha> with the next
//      version and makes its GitHub Release; a commit with a v-tag keeps it. Tags are only on tested commits;
//   3. starts Internal - TestFlight (internal_workflow) and the Mac's (internal_mac_workflow) on ci/release;
//   4. starts PRHub Release (release_workflow, the Public group) on ci/release when the newest change to
//      app/project.yml is a `chore(release): PRHub build N — …` commit that no run of it has built yet.
// Needs ASC_KEY_P8 (the .p8 key's PEM text), ASC_KEY_ID and ASC_ISSUER_ID, and GITHUB_TOKEN and GITHUB_REPOSITORY
// (contents: write, to move ci/release and tag). Workflows are known by their ids in app/ci_scripts/workflows.sh.
// --dry-run prints what it would do, and starts, moves and tags nothing.
// Exits non-zero only when the API or git fails.
import { createPrivateKey, sign } from "node:crypto";
import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { planVersion, publishVersion } from "./version.mjs";

const API = "https://api.appstoreconnect.apple.com/v1/";
const APP_PATHS = ["app/", "PRKit/", "Package.swift", "DESIGN.md"];
const BUSY = new Set(["PENDING", "RUNNING"]);
const ATTEMPTED = new Set(["SUCCEEDED", "FAILED", "ERRORED"]);
const repoRoot = fileURLToPath(new URL("..", import.meta.url));

export function touchesApp(paths) {
  return paths.some((path) =>
    APP_PATHS.some((prefix) => path === prefix || (prefix.endsWith("/") && path.startsWith(prefix))),
  );
}

export const RELEASE_BRANCH = "ci/release";
const RELEASE_SUBJECT = /^chore\(release\): PRHub build \d+ — /;

/**
 * The decision, from Internal - TestFlight's recent runs (newest first: { number, commit, progress, status }), main's
 * head, whether the hourly run already failed on the head, and a `changedSince(commit)` that lists the files changed
 * from that commit to the head. Returns { action: "busy" | "none" | "start", reason, run?, last? }.
 */
export function decide({ runs, head, failedBefore = false, changedSince }) {
  const busy = runs.find((run) => BUSY.has(run.progress));
  if (busy)
    return { action: "busy", reason: `build ${busy.number} is ${busy.progress} (${short(busy.commit)})`, run: busy };
  const atHead = runs.find((run) => run.commit === head && ATTEMPTED.has(run.status));
  if (atHead) return { action: "none", reason: `no change: build ${atHead.number} of ${short(head)} ${atHead.status}` };
  if (failedBefore) return { action: "none", reason: `no release: the hourly run failed on ${short(head)} before` };
  const last = runs.find((run) => run.status === "SUCCEEDED") ?? runs[0];
  if (!last) return { action: "start", reason: `no earlier build; releasing ${short(head)}` };
  if (last.commit === head) return { action: "none", reason: `no change: ${short(head)} is build ${last.number}` };
  const changed = changedSince(last.commit);
  if (changed === null)
    return { action: "start", reason: `build ${last.number}'s ${short(last.commit)} is not in main's history`, last };
  if (!touchesApp(changed)) {
    return {
      action: "none",
      reason: `no change: nothing app-relevant since build ${last.number} (${short(last.commit)})`,
      last,
    };
  }
  return { action: "start", reason: `app changed since build ${last.number} (${short(last.commit)})`, last };
}

/**
 * Whether PRHub Release should build: `release` is the newest commit that changed app/project.yml ({ commit, subject }),
 * `runs` PRHub Release's recent runs, and `contains(run, commit)` says whether a run's commit has `commit` in its history.
 */
export function publicReleaseDue({ release, runs, contains }) {
  if (!release || !RELEASE_SUBJECT.test(release.subject)) return false;
  return !runs.some((run) => run.commit && (BUSY.has(run.progress) || ATTEMPTED.has(run.status)) && contains(run.commit, release.commit));
}

function short(sha) {
  return (sha ?? "?").slice(0, 7);
}

function base64URL(data) {
  return Buffer.from(data).toString("base64url");
}

export function token({ keyPEM, keyID, issuerID, now = Math.floor(Date.now() / 1000) }) {
  const header = base64URL(JSON.stringify({ alg: "ES256", kid: keyID, typ: "JWT" }));
  const claims = base64URL(JSON.stringify({ iss: issuerID, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }));
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), {
    key: createPrivateKey(keyPEM),
    dsaEncoding: "ieee-p1363",
  });
  return `${header}.${claims}.${base64URL(signature)}`;
}

/** A small App Store Connect client: `request(method, path, body?)` returns the parsed JSON document. */
export function client({ keyPEM, keyID, issuerID, fetchImpl = fetch }) {
  return async function request(method, path, body) {
    const response = await fetchImpl(path.startsWith("https://") ? path : API + path, {
      method,
      headers: {
        Authorization: `Bearer ${token({ keyPEM, keyID, issuerID })}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status} ${text}`);
    return JSON.parse(text);
  };
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

function runOf({ id, attributes }) {
  return {
    id,
    number: attributes.number,
    commit: attributes.sourceCommit?.commitSha ?? null,
    progress: attributes.executionProgress,
    status: attributes.completionStatus ?? null,
  };
}

const RUN_FIELDS = "number,executionProgress,completionStatus,sourceCommit";

export async function recentRuns(request, workflowID) {
  const document = await request(
    "GET",
    `ciWorkflows/${workflowID}/buildRuns?sort=-number&limit=10&fields[ciBuildRuns]=${RUN_FIELDS}`,
  );
  return document.data.map(runOf);
}

/** The id of Xcode Cloud's git reference `canonicalName` in the workflow's repository, or null when it has none. */
export async function reference(request, workflowID, canonicalName) {
  const repository = await request(
    "GET",
    `ciWorkflows/${workflowID}/repository?fields[scmRepositories]=repositoryName`,
  );
  let next = `scmRepositories/${repository.data.id}/gitReferences?limit=200&fields[scmGitReferences]=canonicalName,isDeleted`;
  while (next) {
    const page = await request("GET", next);
    const found = page.data.find(
      ({ attributes }) => attributes.canonicalName === canonicalName && !attributes.isDeleted,
    );
    if (found) return found.id;
    next = page.links?.next;
  }
  return null;
}

/** Waits for Xcode Cloud to know `canonicalName` (it learns a new branch from GitHub's push event). */
export async function awaitReference(request, workflowID, canonicalName, { sleep, tries = 20 }) {
  for (let attempt = 0; attempt < tries; attempt++) {
    const id = await reference(request, workflowID, canonicalName);
    if (id) return id;
    await sleep(15_000);
  }
  throw new Error(`Xcode Cloud does not know ${canonicalName}: is the repository's push event reaching it?`);
}

export async function startBuild(request, workflowID, referenceID) {
  const created = await request("POST", "ciBuildRuns", {
    data: {
      type: "ciBuildRuns",
      relationships: {
        workflow: { data: { type: "ciWorkflows", id: workflowID } },
        sourceBranchOrTag: { data: { type: "scmGitReferences", id: referenceID } },
      },
    },
  });
  return runOf(created.data);
}

/**
 * The release of `sha`, whose tests passed: `log` gets one line. `workflows` holds the ids { internal, mac?, release? };
 * `repo` holds `moveReleaseBranch(sha)`, `newestRelease()` ({ commit, subject } of the newest change to app/project.yml
 * at `sha`) and `contains(commit, ancestor)`. `version.plan()` plans the version and `version.publish(plan)` tags `sha`
 * and makes the Release (release/version.mjs), before a build starts, so Xcode Cloud's clone sees the tag.
 */
export async function release({
  request, workflows, sha, version, repo, dryRun, sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  log = console.log,
}) {
  const plan = version.plan();
  const publicDue = workflows.release
    ? publicReleaseDue({
      release: repo.newestRelease(),
      runs: await recentRuns(request, workflows.release),
      contains: repo.contains,
    })
    : false;
  if (dryRun) {
    const also = publicDue ? ", and PRHub Release for the Public group" : "";
    log(`would release ${short(sha)} as ${plan.version} (${plan.action} ${plan.tag ?? "no tag"})${also}`);
    return { plan, publicDue };
  }
  await repo.moveReleaseBranch(sha);
  const ref = await awaitReference(request, workflows.internal, `refs/heads/${RELEASE_BRANCH}`, { sleep });
  const published = await version.publish(plan);
  // Xcode Cloud builds the branch's head as it last heard of it: a moment for GitHub's push event to arrive.
  await sleep(60_000);
  const phone = await startBuild(request, workflows.internal, ref);
  const mac = workflows.mac ? await startBuild(request, workflows.mac, ref) : undefined;
  const pub = publicDue ? await startBuild(request, workflows.release, ref) : undefined;
  const macLine = mac ? ` and the Mac's ${mac.number ?? "?"}` : "";
  const pubLine = pub ? `, and PRHub Release build ${pub.number ?? "?"}` : "";
  log(`started Internal build ${phone.number ?? "?"}${macLine}${pubLine} of ${short(sha)}, ${published}`);
  return { plan, number: phone.number, macNumber: mac?.number, publicNumber: pub?.number };
}

function git(...args) {
  return execFileSync("git", ["-C", repoRoot, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function changedSinceInGit(commit) {
  try {
    git("cat-file", "-e", `${commit}^{commit}`);
  } catch {
    return null;
  }
  const out = git("diff", "--name-only", `${commit}..origin/main`);
  return out ? out.split("\n") : [];
}

/** The commits in `range`, newest first, as `{ subject, body }`. */
function commitsInGit(range) {
  const out = git("log", "--format=%s%x1f%b%x1e", range);
  return out
    .split("\x1e")
    .map((record) => record.replace(/^\n/, ""))
    .filter(Boolean)
    .map((record) => {
      const [subject, body = ""] = record.split("\x1f");
      return { subject, body };
    });
}

/** A workflow's id from app/ci_scripts/workflows.sh; one that is not `required` is undefined when the file has none. */
function workflowIDFromFile(name = "internal_workflow", required = true) {
  const text = readFileSync(new URL("../app/ci_scripts/workflows.sh", import.meta.url), "utf8");
  const id = text.match(new RegExp(`^${name}=(\\S+)$`, "m"))?.[1];
  if (!id && required) throw new Error(`no ${name}= in app/ci_scripts/workflows.sh`);
  return id;
}

const USAGE = "usage: node release/cadence.mjs decide [--dry-run] | release <sha> [--dry-run]";

async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const [mode, sha, ...rest] = args.filter((arg) => arg !== "--dry-run");
  if (!(mode === "decide" && !sha) && !(mode === "release" && /^[0-9a-f]{40}$/.test(sha ?? "")) || rest.length) {
    console.error(USAGE);
    process.exit(2);
  }
  for (const name of ["ASC_KEY_P8", "ASC_KEY_ID", "ASC_ISSUER_ID", ...(dryRun ? [] : ["GITHUB_TOKEN", "GITHUB_REPOSITORY"])]) {
    if (!process.env[name]) {
      console.error(`${name} is not set`);
      process.exit(2);
    }
  }
  const request = client({
    keyPEM: process.env.ASC_KEY_P8,
    keyID: process.env.ASC_KEY_ID,
    issuerID: process.env.ASC_ISSUER_ID,
  });
  const github = process.env.GITHUB_TOKEN && process.env.GITHUB_REPOSITORY
    ? githubClient({ token: process.env.GITHUB_TOKEN, repository: process.env.GITHUB_REPOSITORY })
    : null;
  git("fetch", "--quiet", "--tags", "origin", "main");
  const internal = workflowIDFromFile();

  if (mode === "decide") {
    const head = git("rev-parse", "origin/main");
    // A scheduled hourly run that failed on this head: its tests were red. A run by hand tries again.
    const failed = github && process.env.GITHUB_EVENT_NAME !== "workflow_dispatch"
      ? await github("GET", `actions/workflows/hourly-release.yml/runs?head_sha=${head}&event=schedule&status=failure&per_page=1`)
      : null;
    const decision = decide({
      runs: await recentRuns(request, internal),
      head,
      failedBefore: (failed?.total_count ?? 0) > 0,
      changedSince: changedSinceInGit,
    });
    console.log(decision.reason);
    if (decision.action === "start" && process.env.GITHUB_OUTPUT) {
      appendFileSync(process.env.GITHUB_OUTPUT, `sha=${head}\n`);
    }
    return;
  }

  const lines = (out) => (out ? out.split("\n") : []);
  await release({
    request,
    workflows: {
      internal,
      mac: workflowIDFromFile("internal_mac_workflow", false),
      release: workflowIDFromFile("release_workflow", false),
    },
    sha,
    repo: {
      moveReleaseBranch: async (commit) => {
        const path = `git/refs/heads/${RELEASE_BRANCH}`;
        if (await github("GET", `git/ref/heads/${RELEASE_BRANCH}`)) await github("PATCH", path, { sha: commit, force: true });
        else await github("POST", "git/refs", { ref: `refs/heads/${RELEASE_BRANCH}`, sha: commit });
      },
      newestRelease: () => {
        const commit = git("log", "-1", "--format=%H", sha, "--", "app/project.yml");
        return commit ? { commit, subject: git("log", "-1", "--format=%s", commit) } : null;
      },
      contains: (commit, ancestor) => {
        try {
          git("merge-base", "--is-ancestor", ancestor, commit);
          return true;
        } catch {
          return false;
        }
      },
    },
    version: {
      plan: () =>
        planVersion({
          tags: lines(git("tag", "--merged", sha, "--list", "v*")),
          headTags: lines(git("tag", "--points-at", sha, "--list", "v*")),
          commitsSince: (tag) => commitsInGit(tag ? `${tag}..${sha}` : sha),
        }),
      publish: (plan) => publishVersion(github, plan, sha, (tag) => git("tag", "--list", "--format=%(contents)", tag)),
    },
    dryRun,
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
