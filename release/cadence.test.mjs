// node --test release/cadence.test.mjs — the hourly release's decision and release, on stubbed App Store Connect answers.
import assert from "node:assert/strict";
import { test } from "node:test";
import { decide, publicReleaseDue, release, touchesApp } from "./cadence.mjs";

const HEAD = "h".repeat(40);
const LAST = "a".repeat(40);
const WORKFLOWS = { internal: "wf-internal", mac: "wf-mac", release: "wf-release" };

// `runs` maps a workflow id to its recent runs.
function stubAPI(runs = {}, { knowsBranch = true } = {}) {
  const calls = [];
  const request = async (method, path, body) => {
    calls.push({ method, path, body });
    const list = path.match(/^ciWorkflows\/([\w-]+)\/buildRuns/);
    if (method === "GET" && list) {
      return {
        data: (runs[list[1]] ?? []).map((r) => ({
          id: `run-${r.number}`,
          attributes: {
            number: r.number,
            sourceCommit: { commitSha: r.commit },
            executionProgress: r.progress,
            completionStatus: r.status,
          },
        })),
      };
    }
    if (/^ciWorkflows\/[\w-]+\/repository/.test(path)) return { data: { id: "repo-1" } };
    if (path.startsWith("scmRepositories/repo-1/gitReferences")) {
      const refs = [{ id: "ref-main", attributes: { canonicalName: "refs/heads/main", isDeleted: false } }];
      if (knowsBranch) refs.push({ id: "ref-release", attributes: { canonicalName: "refs/heads/ci/release", isDeleted: false } });
      return { data: refs };
    }
    if (method === "POST" && path === "ciBuildRuns") {
      const number = 9 + calls.filter((c) => c.method === "POST").length - 1;
      return { data: { id: `run-${number}`, attributes: { number, executionProgress: "PENDING" } } };
    }
    throw new Error(`unexpected ${method} ${path}`);
  };
  return { request, calls };
}

const succeeded = { number: 5, commit: LAST, progress: "COMPLETE", status: "SUCCEEDED" };
const posts = (calls) => calls.filter((c) => c.method === "POST");
const startedWorkflows = (calls) => posts(calls).map((post) => post.body.data.relationships.workflow.data.id);

const PLAN = { action: "tag", tag: "v0.18.0", version: "0.18.0", notes: "- feat: x" };

function stubVersion() {
  const published = [];
  return {
    published,
    plan: () => PLAN,
    publish: async (plan) => (published.push(plan), "version 0.18.0 (tagged v0.18.0, release created)"),
  };
}

function stubRepo(newest = null) {
  const moved = [];
  return { moved, moveReleaseBranch: async (sha) => moved.push(sha), newestRelease: () => newest, contains: () => true };
}

async function releaseWith({ runs = {}, repo = stubRepo(), dryRun = false, knowsBranch = true } = {}) {
  const { request, calls } = stubAPI(runs, { knowsBranch });
  const lines = [];
  const version = stubVersion();
  const result = await release({
    request, workflows: WORKFLOWS, sha: HEAD, version, repo, dryRun, sleep: async () => {}, log: (line) => lines.push(line),
  });
  return { result, calls, lines, version, repo };
}

test("a pending or running build: busy", () => {
  for (const progress of ["PENDING", "RUNNING"]) {
    const runs = [{ number: 6, commit: HEAD, progress, status: null }, succeeded];
    assert.equal(decide({ runs, head: HEAD, changedSince: () => ["app/x"] }).action, "busy");
  }
});

test("main's head is the last successful build, or nothing app-relevant changed: no change", () => {
  assert.equal(decide({ runs: [{ ...succeeded, commit: HEAD }], head: HEAD, changedSince: () => [] }).action, "none");
  const changed = ["worker/src/index.ts", "AGENTS.md", "docs/fixtures/a.json"];
  assert.equal(decide({ runs: [succeeded], head: HEAD, changedSince: () => changed }).action, "none");
});

test("an app change is due; not when the hourly run already failed on the head", () => {
  const changedSince = () => ["worker/x", "PRKit/Sources/A.swift"];
  assert.equal(decide({ runs: [succeeded], head: HEAD, changedSince }).action, "start");
  const failed = decide({ runs: [succeeded], head: HEAD, failedBefore: true, changedSince });
  assert.equal(failed.action, "none");
  assert.match(failed.reason, /failed on hhhhhhh before/);
});

test("a release: ci/release moves to the commit, the version is made, then the Internal builds start on ci/release", async () => {
  const { result, calls, lines, version, repo } = await releaseWith();
  assert.deepEqual(repo.moved, [HEAD]);
  assert.deepEqual(version.published, [PLAN]);
  assert.deepEqual(startedWorkflows(calls), [WORKFLOWS.internal, WORKFLOWS.mac]);
  for (const post of posts(calls)) {
    assert.deepEqual(post.body.data.relationships.sourceBranchOrTag, { data: { type: "scmGitReferences", id: "ref-release" } });
  }
  assert.deepEqual([result.number, result.macNumber], [9, 10]);
  assert.match(lines.at(-1), /^started Internal build 9 and the Mac's 10 of hhhhhhh, version 0\.18\.0/);
});

test("a release commit not yet built: PRHub Release starts with the Internal builds", async () => {
  const repo = stubRepo({ commit: HEAD, subject: "chore(release): PRHub build 300 — Things" });
  const { calls, lines } = await releaseWith({ repo });
  assert.deepEqual(startedWorkflows(calls), [WORKFLOWS.internal, WORKFLOWS.mac, WORKFLOWS.release]);
  assert.match(lines.at(-1), /, and PRHub Release build 11 of hhhhhhh/);
});

test("Xcode Cloud never learns ci/release: an error, and no build or tag", async () => {
  const version = stubVersion();
  await assert.rejects(releaseWith({ knowsBranch: false }), /does not know refs\/heads\/ci\/release/);
  assert.deepEqual(version.published, []);
});

test("--dry-run plans the version but starts, moves and tags nothing", async () => {
  const { lines, version, repo, calls } = await releaseWith({ dryRun: true });
  assert.match(lines[0], /^would release hhhhhhh as 0\.18\.0 \(tag v0\.18\.0\)/);
  assert.deepEqual(version.published, []);
  assert.deepEqual(repo.moved, []);
  assert.equal(posts(calls).length, 0);
});

test("PRHub Release is due for a release commit no run has built", () => {
  const newest = { commit: "r".repeat(40), subject: "chore(release): PRHub build 300 — Things" };
  const built = [{ number: 3, commit: HEAD, progress: "COMPLETE", status: "SUCCEEDED" }];
  assert.equal(publicReleaseDue({ release: newest, runs: [], contains: () => true }), true);
  assert.equal(publicReleaseDue({ release: newest, runs: built, contains: () => true }), false);
  assert.equal(publicReleaseDue({ release: newest, runs: built, contains: () => false }), true);
  assert.equal(publicReleaseDue({ release: { ...newest, subject: "ci(app): x" }, runs: [], contains: () => true }), false);
  assert.equal(publicReleaseDue({ release: null, runs: [], contains: () => true }), false);
});

test("the last built commit is the newest success, else the newest run", () => {
  let seen;
  const changedSince = (commit) => ((seen = commit), ["app/x"]);
  const canceled = { number: 7, commit: "c".repeat(40), progress: "COMPLETE", status: "CANCELED" };
  decide({ runs: [canceled, succeeded], head: HEAD, changedSince });
  assert.equal(seen, LAST);
  decide({ runs: [canceled], head: HEAD, changedSince });
  assert.equal(seen, canceled.commit);
});

test("a head whose build failed is not retried; a canceled one is", () => {
  const changedSince = () => ["app/x"];
  const at = (status) => ({ number: 7, commit: HEAD, progress: "COMPLETE", status });
  assert.equal(decide({ runs: [at("FAILED"), succeeded], head: HEAD, changedSince }).action, "none");
  assert.equal(decide({ runs: [at("CANCELED"), succeeded], head: HEAD, changedSince }).action, "start");
});

test("no runs at all, or a last commit missing from history: start", () => {
  assert.equal(decide({ runs: [], head: HEAD, changedSince: () => [] }).action, "start");
  assert.equal(decide({ runs: [succeeded], head: HEAD, changedSince: () => null }).action, "start");
});

test("app paths", () => {
  assert.ok(touchesApp(["Package.swift"]));
  assert.ok(touchesApp(["DESIGN.md"]));
  assert.ok(touchesApp(["app/project.yml"]));
  assert.ok(!touchesApp(["Package.swift.bak", "apps/x", "PRKitty/x", "docs/DESIGN.md"]));
});
