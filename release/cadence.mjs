#!/usr/bin/env node
// Starts Xcode Cloud's Internal - TestFlight workflow on main when main has changed the app since its last build, and
// at most one build at a time. Run every 15 minutes by .github/workflows/internal-testflight.yml:
//   node release/cadence.mjs [--dry-run]
// It does nothing while a build of the workflow is pending or running. Otherwise the last built commit is that of the
// newest run that SUCCEEDED (or, with none in the last 10, the newest run). It starts a build when main's head differs
// from it and the commits between touch app/, PRKit/, Package.swift or DESIGN.md, unless a run at the head already
// succeeded or failed (a failed commit is not retried; the next app change starts a build).
// Before it starts one it makes the build's version (release/version.mjs): a feat or fix since the newest vX.Y.Z tag
// tags main's head with the next version and makes its GitHub Release; a head with a v-tag keeps it.
// With the phone's build it starts the Mac's, Internal - TestFlight (Mac) (internal_mac_workflow), on the same commit:
// a build of its own number, since every workflow of the product shares one sequence.
// Needs ASC_KEY_P8 (the .p8 key's PEM text), ASC_KEY_ID and ASC_ISSUER_ID, and GITHUB_TOKEN (contents: write) and
// GITHUB_REPOSITORY to tag. The workflow is known by its id, internal_workflow in app/ci_scripts/workflows.sh.
// --dry-run prints the decision and the version, and starts and tags nothing.
// Exits non-zero only when the API or git fails.
import { createPrivateKey, sign } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
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

/**
 * The decision, from the workflow's recent runs (newest first: { number, commit, progress, status }), main's head and
 * a `changedSince(commit)` that lists the files changed from that commit to the head.
 * Returns { action: "busy" | "none" | "start", reason, run?, last? }.
 */
export function decide({ runs, head, changedSince }) {
  const busy = runs.find((run) => BUSY.has(run.progress));
  if (busy)
    return { action: "busy", reason: `build ${busy.number} is ${busy.progress} (${short(busy.commit)})`, run: busy };
  const atHead = runs.find((run) => run.commit === head && ATTEMPTED.has(run.status));
  if (atHead) return { action: "none", reason: `no change: build ${atHead.number} of ${short(head)} ${atHead.status}` };
  const last = runs.find((run) => run.status === "SUCCEEDED") ?? runs[0];
  if (!last) return { action: "start", reason: `no earlier build; starting ${short(head)}` };
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

export async function recentRuns(request, workflowID) {
  const fields = "number,executionProgress,completionStatus,sourceCommit";
  const document = await request(
    "GET",
    `ciWorkflows/${workflowID}/buildRuns?sort=-number&limit=10&fields[ciBuildRuns]=${fields}`,
  );
  return document.data.map(({ attributes }) => ({
    number: attributes.number,
    commit: attributes.sourceCommit?.commitSha ?? null,
    progress: attributes.executionProgress,
    status: attributes.completionStatus ?? null,
  }));
}

export async function mainReference(request, workflowID) {
  const repository = await request(
    "GET",
    `ciWorkflows/${workflowID}/repository?fields[scmRepositories]=repositoryName`,
  );
  let next = `scmRepositories/${repository.data.id}/gitReferences?limit=200&fields[scmGitReferences]=canonicalName,isDeleted`;
  while (next) {
    const page = await request("GET", next);
    const main = page.data.find(
      ({ attributes }) => attributes.canonicalName === "refs/heads/main" && !attributes.isDeleted,
    );
    if (main) return main.id;
    next = page.links?.next;
  }
  throw new Error(`Xcode Cloud's repository ${repository.data.id} has no refs/heads/main`);
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
  return created.data.attributes?.number;
}

/**
 * Runs one cadence check. Returns the decision; `log` gets one line. Before a build starts, `version.plan()` plans its
 * version and `version.publish(plan)` tags main's head and makes the Release (release/version.mjs), so Xcode Cloud's
 * clone sees the tag.
 */
export async function run({
  request, workflowID, macWorkflowID, head, changedSince, version, dryRun, log = console.log,
}) {
  const decision = decide({ runs: await recentRuns(request, workflowID), head, changedSince });
  if (decision.action !== "start") {
    log(decision.reason);
    return decision;
  }
  const plan = version.plan();
  if (dryRun) {
    log(`would start a build of ${short(head)} as ${plan.version} (${plan.action} ${plan.tag ?? "no tag"}): ${decision.reason}`);
    return { ...decision, plan };
  }
  const published = await version.publish(plan);
  const number = await startBuild(request, workflowID, await mainReference(request, workflowID));
  // The Mac's follows the phone's decision: one cadence, and the phone's runs are the record of what was built.
  const macNumber = macWorkflowID
    ? await startBuild(request, macWorkflowID, await mainReference(request, macWorkflowID))
    : undefined;
  const mac = macWorkflowID ? ` and the Mac's ${macNumber ?? "?"}` : "";
  log(`started build ${number ?? "?"}${mac} of ${short(head)}, ${published}: ${decision.reason}`);
  return { ...decision, plan, number, macNumber };
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

async function main() {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== "--dry-run")) {
    console.error("usage: node release/cadence.mjs [--dry-run]");
    process.exit(2);
  }
  const dryRun = args.includes("--dry-run");
  for (const name of ["ASC_KEY_P8", "ASC_KEY_ID", "ASC_ISSUER_ID", ...(dryRun ? [] : ["GITHUB_TOKEN", "GITHUB_REPOSITORY"])]) {
    if (!process.env[name]) {
      console.error(`${name} is not set`);
      process.exit(2);
    }
  }
  git("fetch", "--quiet", "--tags", "origin", "main");
  const head = git("rev-parse", "origin/main");
  const lines = (out) => (out ? out.split("\n") : []);
  const github = dryRun
    ? null
    : githubClient({ token: process.env.GITHUB_TOKEN, repository: process.env.GITHUB_REPOSITORY });
  await run({
    request: client({
      keyPEM: process.env.ASC_KEY_P8,
      keyID: process.env.ASC_KEY_ID,
      issuerID: process.env.ASC_ISSUER_ID,
    }),
    workflowID: workflowIDFromFile(),
    macWorkflowID: workflowIDFromFile("internal_mac_workflow", false),
    head,
    changedSince: changedSinceInGit,
    version: {
      plan: () =>
        planVersion({
          tags: lines(git("tag", "--merged", head, "--list", "v*")),
          headTags: lines(git("tag", "--points-at", head, "--list", "v*")),
          commitsSince: (tag) => commitsInGit(tag ? `${tag}..${head}` : head),
        }),
      publish: (plan) => publishVersion(github, plan, head, (tag) => git("tag", "--list", "--format=%(contents)", tag)),
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
