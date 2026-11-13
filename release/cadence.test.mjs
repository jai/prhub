// node --test release/cadence.test.mjs — the Internal TestFlight cadence's decision, on stubbed App Store Connect answers.
import assert from "node:assert/strict";
import { test } from "node:test";
import { decide, run, touchesApp } from "./cadence.mjs";

const HEAD = "h".repeat(40);
const LAST = "a".repeat(40);
const WORKFLOW = "workflow-1";

function stubAPI(runs) {
  const calls = [];
  const request = async (method, path, body) => {
    calls.push({ method, path, body });
    if (method === "GET" && path.startsWith(`ciWorkflows/${WORKFLOW}/buildRuns`)) {
      return {
        data: runs.map((r) => ({
          attributes: {
            number: r.number,
            sourceCommit: { commitSha: r.commit },
            executionProgress: r.progress,
            completionStatus: r.status,
          },
        })),
      };
    }
    if (path.startsWith(`ciWorkflows/${WORKFLOW}/repository`)) return { data: { id: "repo-1" } };
    if (path.startsWith("scmRepositories/repo-1/gitReferences")) {
      return {
        data: [
          { id: "ref-dev", attributes: { canonicalName: "refs/heads/dev", isDeleted: false } },
          { id: "ref-main", attributes: { canonicalName: "refs/heads/main", isDeleted: false } },
        ],
      };
    }
    if (method === "POST" && path === "ciBuildRuns") return { data: { id: "run-9", attributes: { number: 9 } } };
    throw new Error(`unexpected ${method} ${path}`);
  };
  return { request, calls };
}

const succeeded = { number: 5, commit: LAST, progress: "COMPLETE", status: "SUCCEEDED" };
const posts = (calls) => calls.filter((c) => c.method === "POST");

async function check(runs, changed) {
  const { request, calls } = stubAPI(runs);
  const lines = [];
  const decision = await run({
    request,
    workflowID: WORKFLOW,
    head: HEAD,
    changedSince: () => changed,
    dryRun: false,
    log: (line) => lines.push(line),
  });
  assert.equal(lines.length, 1);
  return { decision, calls, line: lines[0] };
}

test("a pending or running build: nothing starts", async () => {
  for (const progress of ["PENDING", "RUNNING"]) {
    const { decision, calls } = await check(
      [{ number: 6, commit: HEAD, progress, status: null }, succeeded],
      ["app/x"],
    );
    assert.equal(decision.action, "busy");
    assert.equal(posts(calls).length, 0);
  }
});

test("main's head is the last successful build: no change", async () => {
  const { decision, calls, line } = await check([{ ...succeeded, commit: HEAD }], []);
  assert.equal(decision.action, "none");
  assert.match(line, /^no change/);
  assert.equal(posts(calls).length, 0);
});

test("changes outside the app paths: no change", async () => {
  const { decision, calls } = await check([succeeded], ["worker/src/index.ts", "AGENTS.md", "docs/fixtures/a.json"]);
  assert.equal(decision.action, "none");
  assert.equal(posts(calls).length, 0);
});

test("a change inside the app paths starts the workflow on main", async () => {
  const { decision, calls, line } = await check([succeeded], ["worker/x", "PRKit/Sources/A.swift"]);
  assert.equal(decision.action, "start");
  assert.equal(decision.number, 9);
  assert.match(line, /^started build 9/);
  const [post] = posts(calls);
  assert.deepEqual(post.body.data.relationships, {
    workflow: { data: { type: "ciWorkflows", id: WORKFLOW } },
    sourceBranchOrTag: { data: { type: "scmGitReferences", id: "ref-main" } },
  });
});

test("--dry-run decides but starts nothing", async () => {
  const { request, calls } = stubAPI([succeeded]);
  const lines = [];
  const decision = await run({
    request,
    workflowID: WORKFLOW,
    head: HEAD,
    changedSince: () => ["app/x"],
    dryRun: true,
    log: (l) => lines.push(l),
  });
  assert.equal(decision.action, "start");
  assert.match(lines[0], /^would start/);
  assert.equal(calls.length, 1);
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
