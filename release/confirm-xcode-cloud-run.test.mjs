import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { INTERVAL, PATIENCE, REPUSHES, confirm, repushTag, runFor } from "./confirm-xcode-cloud-run.mjs";

const TAG = "ios-v0.39.0";
const LOOKS = PATIENCE / INTERVAL + 1;

/** App Store Connect's build runs document: each run is [number, the name of its tag or branch, "TAG" or "BRANCH"]. */
function buildRuns(...runs) {
  return {
    data: runs.map(([number, name, kind = "TAG"]) => ({
      id: `run${number}`,
      attributes: { number, createdDate: `2026-11-25T0${number % 10}:00:00Z` },
      relationships: { sourceBranchOrTag: { data: { type: "scmGitReferences", id: `${kind}-${name}` } } },
    })),
    included: runs.map(([, name, kind = "TAG"]) => ({
      type: "scmGitReferences", id: `${kind}-${name}`, attributes: { name, kind },
    })),
  };
}

/**
 * A stubbed App Store Connect and a stubbed push. `answers` are what Xcode Cloud's runs are at each look, in order; the
 * last one stays. An answer that is an Error is a look that fails.
 */
function stub(answers) {
  const calls = { looks: 0, pushes: 0, slept: 0, log: [] };
  const request = async (method, path) => {
    if (path.startsWith("apps/")) return { data: { id: "product1" } };
    const answer = answers[Math.min(calls.looks, answers.length - 1)];
    calls.looks += 1;
    if (answer instanceof Error) throw answer;
    return answer;
  };
  return {
    calls,
    options: {
      tag: TAG,
      find: () => runFor(request, TAG),
      repush: async () => {
        calls.pushes += 1;
      },
      sleep: async (seconds) => {
        calls.slept += seconds;
      },
      log: (line) => calls.log.push(line),
    },
  };
}

test("Xcode Cloud's run for a tag is found by the tag's name, among other tags and a branch of that name", async () => {
  const paths = [];
  const request = async (method, path) => {
    paths.push(`${method} ${path}`);
    return path.startsWith("apps/")
      ? { data: { id: "product1" } }
      : buildRuns([314, "ios-v0.40.0"], [313, TAG, "BRANCH"], [312, TAG], [311, "ios-v0.38.0"]);
  };
  assert.deepEqual(await runFor(request, TAG), { number: 312, created: "2026-11-25T02:00:00Z" });
  assert.equal(await runFor(request, "ios-v0.37.0"), undefined);
  assert.equal(paths[0], "GET apps/6831601628/ciProduct?fields[ciProducts]=name");
  assert.match(paths[1], /^GET ciProducts\/product1\/buildRuns\?sort=-number&limit=25&include=sourceBranchOrTag&/);
});

test("a run that is there at once: nothing is pushed again and nothing waits", async () => {
  const { calls, options } = stub([buildRuns([313, TAG])]);
  assert.equal((await confirm(options)).number, 313);
  assert.deepEqual([calls.looks, calls.pushes, calls.slept], [1, 0, 0]);
});

test("a run that starts a little late is waited for, not pushed for", async () => {
  const none = buildRuns([312, "ios-v0.38.0"]);
  const { calls, options } = stub([none, none, buildRuns([313, TAG])]);
  assert.equal((await confirm(options)).number, 313);
  assert.deepEqual([calls.looks, calls.pushes, calls.slept], [3, 0, 2 * INTERVAL]);
});

test("no run after the wait: the tag is pushed again, and the run that push starts is the answer", async () => {
  const none = buildRuns([312, "ios-v0.38.0"]);
  const { calls, options } = stub([...Array(LOOKS).fill(none), buildRuns([313, TAG])]);
  assert.equal((await confirm(options)).number, 313);
  assert.deepEqual([calls.looks, calls.pushes, calls.slept], [LOOKS + 1, 1, PATIENCE]);
  assert.match(calls.log[0], /No Xcode Cloud run for ios-v0\.39\.0 after 180 s\. Pushing the tag again \(1 of 2\)/);
});

test("a run that never starts: the tag is pushed again twice and no more, then it fails and says what to do", async () => {
  const { calls, options } = stub([buildRuns([312, "ios-v0.38.0"])]);
  await assert.rejects(confirm(options), (error) => {
    assert.match(error.message, /started no run for ios-v0\.39\.0: the tag was pushed 3 times/);
    assert.match(error.message, /What to do: .*Xcode Cloud.*re-run this job/);
    return true;
  });
  assert.equal(calls.pushes, REPUSHES);
  assert.equal(calls.looks, (REPUSHES + 1) * LOOKS);
  assert.equal(calls.slept, (REPUSHES + 1) * PATIENCE);
});

test("a look that fails is tried again", async () => {
  const { calls, options } = stub([new Error("HTTP 503"), buildRuns([313, TAG])]);
  assert.equal((await confirm(options)).number, 313);
  assert.deepEqual([calls.looks, calls.pushes], [2, 0]);
});

test("App Store Connect not answering is not 'no run': nothing is pushed again", async () => {
  const { calls, options } = stub([new Error("HTTP 503")]);
  await assert.rejects(confirm(options), /App Store Connect did not answer, so nothing was pushed again: HTTP 503/);
  assert.deepEqual([calls.looks, calls.pushes], [LOOKS, 0]);
});

test("a dry run looks once, waits for nothing and pushes nothing", async () => {
  const missing = stub([buildRuns([312, "ios-v0.38.0"])]);
  await assert.rejects(confirm({ ...missing.options, dryRun: true }), /has no run for ios-v0\.39\.0\. Dry run: nothing was pushed/);
  assert.deepEqual([missing.calls.looks, missing.calls.pushes, missing.calls.slept], [1, 0, 0]);

  const found = stub([buildRuns([313, TAG])]);
  assert.equal((await confirm({ ...found.options, dryRun: true })).number, 313);
  assert.deepEqual([found.calls.looks, found.calls.pushes, found.calls.slept], [1, 0, 0]);
});

/** A throwaway origin and a checkout of it with an annotated tag pushed, as the release job has them. */
function repositories(t) {
  const root = mkdtempSync(join(tmpdir(), "confirm-xcode-cloud-run-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const git = (cwd, ...args) =>
    execFileSync("git", ["-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "tag.gpgsign=false", ...args], {
      cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  const origin = join(root, "origin.git");
  const checkout = join(root, "checkout");
  git(root, "init", "--quiet", "--bare", origin);
  git(root, "init", "--quiet", checkout);
  git(checkout, "remote", "add", "origin", origin);
  git(checkout, "commit", "--quiet", "--allow-empty", "-m", "a release");
  git(checkout, "tag", "-a", TAG, "-m", "notes");
  git(checkout, "push", "--quiet", "origin", `refs/tags/${TAG}`);
  return { git, origin, checkout };
}

test("pushing again deletes origin's tag and pushes the same tag object", (t) => {
  const { git, origin, checkout } = repositories(t);
  const object = git(origin, "rev-parse", `refs/tags/${TAG}`);
  // What origin receives, one line for each change to a ref, as GitHub turns each into an event: "<old> <new> <ref>".
  const received = join(origin, "received");
  writeFileSync(join(origin, "hooks", "post-receive"), `#!/bin/sh\ncat >> "${received}"\n`, { mode: 0o755 });
  repushTag(TAG, { cwd: checkout });
  const none = "0".repeat(object.length);
  assert.deepEqual(readFileSync(received, "utf8").trim().split("\n"), [
    `${object} ${none} refs/tags/${TAG}`,
    `${none} ${object} refs/tags/${TAG}`,
  ]);
  assert.equal(git(origin, "rev-parse", `refs/tags/${TAG}`), object);
});

test("a tag that someone moved on origin is left alone", (t) => {
  const { git, origin, checkout } = repositories(t);
  git(origin, "tag", "-f", "-a", TAG, "-m", "moved by someone else", `${TAG}^{commit}`);
  const moved = git(origin, "rev-parse", `refs/tags/${TAG}`);
  assert.throws(() => repushTag(TAG, { cwd: checkout }));
  assert.equal(git(origin, "rev-parse", `refs/tags/${TAG}`), moved);
});
