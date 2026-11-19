import assert from "node:assert/strict";
import { afterEach, test } from "vitest";
import { readPullRequests, searchListings } from "../../../src/github.ts";
import { prId, repoOf } from "../../../src/ids.ts";
import { prNode } from "../../support/pr-node.ts";
import { env, gitHub } from "../../support/read-token-responses.ts";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});
const THREAD = {
  id: "T1",
  isResolved: false,
  isOutdated: false,
  path: "src/upload.ts",
  line: 3,
  diffSide: "RIGHT",
  comments: { nodes: [] },
};
const VIEWER = {
  viewerDidAuthor: true,
  repository: { viewerDefaultMergeMethod: "MERGE" },
  files: { nodes: [{ path: "src/retry.ts", viewerViewedState: "VIEWED" }] },
  reviewThreads: { nodes: [{ id: "T1", viewerCanResolve: true, viewerCanUnresolve: false }] },
};
const REF = { id: prId(repoOf("acme/app"), 7), repo: repoOf("acme/app"), number: 7 };

test("a PR's detail is read with the read token, and only the owner's own view of it as the owner", async () => {
  const {
    viewerDidAuthor: _a,
    files: _f,
    ...shared
  } = prNode({ reviewThreads: { nodes: [THREAD] } });
  const calls = gitHub((query) => ({
    data: { p0: { pullRequest: query.includes("...Fields") ? shared : VIEWER } },
  }));
  const read = await readPullRequests([REF], env(), new Set(), async () => new Map());
  const graphql = calls.filter((call) => call.url.endsWith("/graphql"));
  assert.deepEqual(
    graphql.map((call) => [call.token, /\bviewer/.test(call.query)]),
    [
      ["reader", false],
      ["owner", true],
    ],
  );
  assert.ok(calls.filter((call) => call.method === "GET").every((call) => call.token === "reader"));
  const detail = read.get(REF.id)?.detail;
  assert.equal(detail?.isAuthor, true);
  assert.equal(detail?.mergeMethod, "MERGE");
  assert.deepEqual(detail?.viewedFiles, ["src/retry.ts"]);
  assert.deepEqual(
    detail?.reviewThreads.nodes.map((thread) => [
      thread.viewerCanResolve,
      thread.viewerCanUnresolve,
    ]),
    [[true, false]],
  );
});

test("unset, and on the hosted Worker, every call goes with GITHUB_TOKEN as before: one detail query", async () => {
  for (const vars of [{ GITHUB_READ_TOKEN: undefined }, { SIGNED_IN_USER_ID: "1" }]) {
    const calls = gitHub(() => ({ data: { p0: { pullRequest: prNode() } } }));
    await readPullRequests([REF], env(vars), new Set(), async () => new Map());
    await searchListings(env(vars)).catch(() => null);
    assert.deepEqual(new Set(calls.map((call) => call.token)), new Set(["owner"]));
    assert.equal(calls.filter((call) => call.query.includes("...Viewer")).length, 1);
  }
});
