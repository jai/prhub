import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import type { Env } from "../src/env.ts";
import {
  graphql, mergedPullRequests, postToGitHub, readPullRequests, searchListings, sendToGitHub,
} from "../src/github.ts";
import { prId, repoOf } from "../src/ids.ts";
import { prNode } from "./pr-node.ts";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

interface Call { url: string; token: string; method: string; query: string; q: unknown }

/** Every GitHub call, with the token it went with; `answer` says what GitHub answers a GraphQL query. */
function gitHub(answer: (query: string) => unknown = () => ({ data: {} })): Call[] {
  const calls: Call[] = [];
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    const token = new Headers(init.headers).get("authorization")?.replace("Bearer ", "") ?? "";
    const body = typeof init.body === "string" ? JSON.parse(init.body) as { query?: string; variables?: { q?: unknown } }
      : {};
    calls.push({ url, token, method: init.method ?? "GET", query: body.query ?? "", q: body.variables?.q });
    if (url.endsWith("/user")) {
      return Response.json({ login: token === "owner" ? "jai" : "jai-bot-reviewer" });
    }
    if (url.endsWith("/graphql")) {
      return Response.json(answer(body.query ?? ""));
    }
    return new Response(null, { status: url.includes(".policy.yml") ? 404 : 201 });
  }) as typeof fetch;
  return calls;
}

const EMPTY_SEARCH = { data: { search: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } };
const env = (vars: Partial<Env> = {}) =>
  ({ GITHUB_TOKEN: "owner", GITHUB_READ_TOKEN: "reader", GITHUB_LOGIN: "jai", ...vars }) as Env;

test("the searches go with the read token and name the owner, never @me", async () => {
  const calls = gitHub(() => EMPTY_SEARCH);
  await searchListings(env());
  await mergedPullRequests(env(), "reviewed");
  assert.deepEqual(new Set(calls.map((call) => call.token)), new Set(["reader"]));
  const qs = calls.map((call) => String(call.q));
  assert.ok(qs.every((q) => !q.includes("@me")), qs.join("\n"));
  assert.ok(qs.some((q) => q.includes("user-review-requested:jai")));
  assert.ok(qs.some((q) => q.includes("reviewed-by:jai -author:jai")));
});

test("without GITHUB_LOGIN the owner is GITHUB_TOKEN's user, not the read token's", async () => {
  const calls = gitHub(() => EMPTY_SEARCH);
  await searchListings(env({ GITHUB_LOGIN: undefined }));
  assert.equal(calls.find((call) => call.url.endsWith("/user"))?.token, "owner");
  assert.ok(calls.some((call) => String(call.q).includes("author:jai")));
});

test("every write goes with GITHUB_TOKEN", async () => {
  const calls = gitHub(() => ({ data: { resolveReviewThread: { thread: { id: "T1" } } } }));
  await postToGitHub("/repos/acme/app/issues/7/comments", { body: "Looks right." }, env());
  await sendToGitHub("PUT", "/repos/acme/app/pulls/7/merge", { merge_method: "squash" }, env());
  await graphql(`mutation($thread: ID!) { resolveReviewThread(input: { threadId: $thread }) { thread { id } } }`,
    { thread: "T1" }, env());
  assert.deepEqual(calls.map((call) => [call.method, call.token]), [["POST", "owner"], ["PUT", "owner"], ["POST", "owner"]]);
});

const THREAD = { id: "T1", isResolved: false, isOutdated: false, path: "src/upload.ts", line: 3, diffSide: "RIGHT",
  comments: { nodes: [] } };
const VIEWER = { viewerDidAuthor: true, repository: { viewerDefaultMergeMethod: "MERGE" },
  files: { nodes: [{ path: "src/retry.ts", viewerViewedState: "VIEWED" }] },
  reviewThreads: { nodes: [{ id: "T1", viewerCanResolve: true, viewerCanUnresolve: false }] } };
const REF = { id: prId(repoOf("acme/app"), 7), repo: repoOf("acme/app"), number: 7 };

test("a PR's detail is read with the read token, and only the owner's own view of it as the owner", async () => {
  const { viewerDidAuthor: _a, files: _f, ...shared } = prNode({ reviewThreads: { nodes: [THREAD] } });
  const calls = gitHub((query) => ({
    data: { p0: { pullRequest: query.includes("...Fields") ? shared : VIEWER } },
  }));
  const read = await readPullRequests([REF], env(), new Set(), async () => new Map());
  const graphql = calls.filter((call) => call.url.endsWith("/graphql"));
  assert.deepEqual(graphql.map((call) => [call.token, /\bviewer/.test(call.query)]), [["reader", false], ["owner", true]]);
  assert.ok(calls.filter((call) => call.method === "GET").every((call) => call.token === "reader"));
  const detail = read.get(REF.id)?.detail;
  assert.equal(detail?.isAuthor, true);
  assert.equal(detail?.mergeMethod, "MERGE");
  assert.deepEqual(detail?.viewedFiles, ["src/retry.ts"]);
  assert.deepEqual(detail?.reviewThreads.nodes.map((thread) => [thread.viewerCanResolve, thread.viewerCanUnresolve]),
    [[true, false]]);
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
