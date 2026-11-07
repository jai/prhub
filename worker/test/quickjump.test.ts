import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import {
  ALERT_FRESH_MS, alertKey, alertKinds, alertMessage, alertsFor, type HeldStatus, type ReadPullRequest,
} from "../src/alerts.ts";
import { relayBody, sendDirect, SYNC_WAKE } from "../src/apns.ts";
import type { Env } from "../src/env.ts";
import { pullRequestSummary, summaryOf } from "../src/github.ts";
import {
  buildRepoIndex, fetchRepoIndex, isRepoIndex, MAX_REPOS, ownersOf, rankRepos, type RepoIndex,
} from "../src/repos.ts";

const env = (vars: Partial<Env>) => ({ GITHUB_TOKEN: "t", ...vars }) as Env;
const NOW = Date.parse("2026-11-07T10:00:00Z");
const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

/** Answers each GitHub GraphQL call from `answer`, and keeps what was asked. */
function mockGraphql(answer: (query: string, variables: Record<string, unknown>) => unknown) {
  const asked: { query: string; variables: Record<string, unknown> }[] = [];
  globalThis.fetch = (async (_url: string, init: RequestInit) => {
    const { query, variables } = JSON.parse(String(init.body)) as { query: string; variables: Record<string, unknown> };
    asked.push({ query, variables });
    return Response.json(answer(query, variables));
  }) as typeof fetch;
  return asked;
}

function read(fields: Partial<ReadPullRequest> = {}): ReadPullRequest {
  return {
    repo: "acme/api", number: 7, head: "a".repeat(40), title: "Add retries", list: "review", review: "required",
    requestedAt: new Date(NOW - 60_000).toISOString(), ...fields,
  };
}

const requests = alertKinds(env({}));
const all = alertKinds(env({ PR_ALERTS: "review_requested, approved,changes_requested" }));

test("alerts default to review requests, follow PR_ALERTS, and turn off with off", () => {
  assert.deepEqual([...requests], ["review_requested"]);
  assert.deepEqual([...alertKinds(env({ PR_ALERTS: "  " }))], ["review_requested"]);
  assert.deepEqual([...all], ["review_requested", "approved", "changes_requested"]);
  assert.deepEqual([...alertKinds(env({ PR_ALERTS: "Approved,nonsense" }))], ["approved"]);
  assert.equal(alertKinds(env({ PR_ALERTS: "off" })).size, 0);
});

test("a PR coming onto the review list alerts once, while the request is fresh", () => {
  assert.deepEqual(alertsFor(null, read(), requests, NOW).map((alert) => alert.kind), ["review_requested"]);
  const reviewed: HeldStatus = { list: "reviewed", review: "required" };
  assert.equal(alertsFor(reviewed, read(), requests, NOW).length, 1, "asked again after answering");
  assert.equal(alertsFor({ list: "review", review: "required" }, read(), requests, NOW).length, 0, "already asked");
  const old = new Date(NOW - ALERT_FRESH_MS - 1).toISOString();
  assert.equal(alertsFor(null, read({ requestedAt: old }), requests, NOW).length, 0, "a new Worker's first sync");
  assert.equal(alertsFor(null, read({ requestedAt: null }), requests, NOW).length, 0);
  assert.equal(alertsFor(null, read({ list: "mine" }), requests, NOW).length, 0);
  assert.equal(alertsFor(null, read(), alertKinds(env({ PR_ALERTS: "off" })), NOW).length, 0);
});

test("a decision on the user's own PR alerts when it changes, and only when turned on", () => {
  const mine = (review: string) => read({ list: "mine", review, requestedAt: null });
  const held = (review: string): HeldStatus => ({ list: "mine", review });
  assert.deepEqual(alertsFor(held("required"), mine("approved"), all, NOW).map((alert) => alert.kind), ["approved"]);
  assert.deepEqual(alertsFor(held("approved"), mine("changes_requested"), all, NOW).map((alert) => alert.kind),
    ["changes_requested"]);
  assert.equal(alertsFor(held("approved"), mine("approved"), all, NOW).length, 0, "no change");
  assert.equal(alertsFor(null, mine("approved"), all, NOW).length, 0, "first seen: history, not news");
  assert.equal(alertsFor(held("required"), mine("approved"), requests, NOW).length, 0, "off by default");
  assert.equal(alertsFor(held("approved"), mine("required"), all, NOW).length, 0, "a decision going away says nothing");
});

test("an alert is one per kind, PR and head: a re-request at the same commit is hushed, a new push is not", () => {
  const [alert] = alertsFor(null, read(), requests, NOW);
  assert.equal(alertKey(alert), `review_requested:acme/api#7@${"a".repeat(40)}`);
  assert.notEqual(alertKey({ ...alert, head: "b".repeat(40) }), alertKey(alert));
  assert.notEqual(alertKey({ ...alert, kind: "approved" }), alertKey(alert));
});

test("an alert names the PR for a tap to open, and fits APNs whatever the title", () => {
  const [alert] = alertsFor(null, read(), requests, NOW);
  const message = alertMessage(alert);
  assert.deepEqual(message.payload, {
    aps: {
      alert: { title: "Review requested: acme/api#7", body: "Add retries" }, sound: "default", "thread-id": "pr:acme/api#7",
    },
    reason: "pr_alert",
    kind: "review_requested",
    pr: { repo: "acme/api", number: 7 },
  });
  assert.equal(message.pushType, "alert");
  assert.equal(message.priority, 10);
  const long = alertMessage({ ...alert, repo: `${"o".repeat(39)}/${"r".repeat(100)}`, title: "標題".repeat(500) });
  const aps = long.payload.aps as { alert: { title: string; body: string }; "thread-id": string };
  assert.ok(Array.from(aps.alert.body).length <= 240 && aps.alert.body.endsWith("…"));
  assert.ok(Array.from(aps.alert.title).length <= 120);
  assert.ok(aps["thread-id"].length <= 64);
  assert.ok(new TextEncoder().encode(JSON.stringify(long.payload)).byteLength < 4096);
});

test("through the relay an alert is a priority-10 alert push with no collapse id; the wake is unchanged", () => {
  const [alert] = alertsFor(null, read(), requests, NOW);
  const body = relayBody("abcd", "production", 1_000, alertMessage(alert)) as Record<string, unknown>;
  assert.equal(body.push_type, "alert");
  assert.equal(body.priority, 10);
  assert.equal(body.collapse_id, null);
  assert.equal(body.expiration, 1_000 + 86_400);
  assert.deepEqual((body.payload as { pr: unknown }).pr, { repo: "acme/api", number: 7 });
  assert.deepEqual(relayBody("abcd", "production", 1_000), relayBody("abcd", "production", 1_000, SYNC_WAKE));
});

test("straight to APNs an alert sends alert headers, and the wake keeps its own", async () => {
  const sent: { url: string; headers: Record<string, string>; body: string }[] = [];
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    sent.push({ url, headers: init.headers as Record<string, string>, body: String(init.body) });
    return new Response(null, { status: 200 });
  }) as typeof fetch;
  const apns = env({ APNS_BUNDLE_ID: "com.example.app" });
  const [alert] = alertsFor(null, read(), requests, NOW);
  assert.deepEqual(await sendDirect("abcd", "sandbox", "jwt", apns, 1_000, alertMessage(alert)), { status: 200, reason: null });
  await sendDirect("abcd", "production", "jwt", apns, 1_000);
  assert.equal(sent[0].url, "https://api.sandbox.push.apple.com/3/device/abcd");
  assert.equal(sent[0].headers["apns-push-type"], "alert");
  assert.equal(sent[0].headers["apns-priority"], "10");
  assert.equal(sent[0].headers["apns-collapse-id"], undefined);
  assert.equal(JSON.parse(sent[0].body).reason, "pr_alert");
  assert.equal(sent[1].headers["apns-push-type"], "background");
  assert.equal(sent[1].headers["apns-collapse-id"], "pr-sync");
  assert.deepEqual(JSON.parse(sent[1].body), { aps: { "content-available": 1 }, reason: "pr_sync" });
});

test("a network failure straight to APNs is a reason, not a throw", async () => {
  globalThis.fetch = (async () => {
    throw new TypeError("network");
  }) as typeof fetch;
  assert.deepEqual(await sendDirect("abcd", "production", "jwt", env({}), 1_000),
    { status: null, reason: "fetch_error: network" });
});

const repoNode = (nameWithOwner: string, pushedAt: string | null, fields: object = {}) => ({
  nameWithOwner, name: nameWithOwner.split("/")[1], isArchived: false, pushedAt, pullRequests: { totalCount: 1 }, ...fields,
});

test("the repo index lists each repo once, with its owners, newest push first when cut", () => {
  const index = buildRepoIndex([
    repoNode("acme/api", "2026-11-01T00:00:00Z"), repoNode("jai/notes", "2026-11-05T00:00:00Z"),
    repoNode("Acme/API", "2026-11-01T00:00:00Z"), repoNode("acme/old", null, { isArchived: true }),
  ], new Map([["jai/notes", 3]]), NOW);
  assert.equal(index.repos.length, 3);
  assert.deepEqual(new Set(index.owners), new Set(["Acme", "acme", "jai"]));
  assert.deepEqual(index.repos[0], {
    nameWithOwner: "jai/notes", name: "notes", archived: false, pushedAt: "2026-11-05T00:00:00Z", openPrs: 1,
    recentPrs: 3, listed: 0,
  });
  assert.equal(index.updatedAt, "2026-11-07T10:00:00.000Z");
  assert.equal(index.truncated, false);
  assert.ok(isRepoIndex(index));
  assert.ok(!isRepoIndex({ repos: [] }));
  const many = Array.from({ length: MAX_REPOS + 2 }, (_, n) =>
    repoNode(`acme/r${n}`, new Date(NOW - n * 1_000).toISOString()));
  const cut = buildRepoIndex(many, new Map(), NOW);
  assert.equal(cut.repos.length, MAX_REPOS);
  assert.equal(cut.truncated, true);
  assert.equal(cut.repos.at(-1)?.nameWithOwner, `acme/r${MAX_REPOS - 1}`);
});

test("repos rank by the user's list, then recent work, then last push, archived last", () => {
  const index: RepoIndex = buildRepoIndex([
    repoNode("acme/quiet", "2026-11-06T00:00:00Z"), repoNode("acme/busy", "2026-10-01T00:00:00Z"),
    repoNode("acme/listed", "2026-09-01T00:00:00Z"), repoNode("acme/gone", "2026-11-07T00:00:00Z", { isArchived: true }),
  ], new Map([["acme/busy", 9], ["acme/gone", 50]]), NOW);
  const ranked = rankRepos(index, new Map([["acme/listed", 2]]));
  assert.deepEqual(ranked.repos.map((repo) => repo.nameWithOwner), ["acme/listed", "acme/busy", "acme/quiet", "acme/gone"]);
  assert.equal(ranked.repos[0].listed, 2);
  assert.equal(index.repos.every((repo) => repo.listed === 0), true, "the stored copy is left alone");
});

test("GITHUB_ORGS names the owners; unset, the index is every repo the user owns or sees through an org", async () => {
  assert.deepEqual(ownersOf(env({ GITHUB_ORGS: "acme, ,jai" })), ["acme", "jai"]);
  assert.deepEqual(ownersOf(env({})), []);
  const asked = mockGraphql((query, variables) => {
    if (query.includes("search(")) {
      return { data: { search: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [
        { repository: { nameWithOwner: "acme/api" } }, { repository: { nameWithOwner: "acme/api" } }, {},
      ] } } };
    }
    const first = variables.after === null;
    return { data: { viewer: { repositories: {
      pageInfo: { hasNextPage: first, endCursor: first ? "c1" : null },
      nodes: first ? [repoNode("acme/api", "2026-11-01T00:00:00Z"), null] : [repoNode("jai/notes", "2026-11-02T00:00:00Z")],
    } } } };
  });
  const index = await fetchRepoIndex(env({}), NOW);
  assert.deepEqual(index.repos.map((repo) => [repo.nameWithOwner, repo.recentPrs]), [["jai/notes", 0], ["acme/api", 2]]);
  assert.deepEqual(index.owners, ["acme", "jai"]);
  const viewerQueries = asked.filter(({ query }) => query.includes("viewer"));
  assert.deepEqual(viewerQueries.map(({ variables }) => variables.after), [null, "c1"]);
  assert.match(asked.find(({ query }) => query.includes("search("))?.variables.q as string,
    /^is:pr involves:@me updated:>=2026-08-09$/);
});

test("an owner GitHub won't show costs only that owner, and a failed relevance search only the hint", async () => {
  mockGraphql((query, variables) => {
    if (query.includes("search(")) {
      return { errors: [{ type: "RATE_LIMITED" }] };
    }
    return variables.owner === "acme"
      ? { data: { repositoryOwner: { repositories: { pageInfo: { hasNextPage: false, endCursor: null },
        nodes: [repoNode("acme/api", "2026-11-01T00:00:00Z")] } } } }
      : { data: { repositoryOwner: null }, errors: [{ type: "NOT_FOUND" }] };
  });
  const index = await fetchRepoIndex(env({ GITHUB_ORGS: "acme,ghost" }), NOW);
  assert.deepEqual(index.repos.map((repo) => repo.nameWithOwner), ["acme/api"]);
  assert.equal(index.repos[0].recentPrs, 0);
});

test("a repo index GitHub refuses outright is an error, so the stored copy stands", async () => {
  mockGraphql(() => ({ errors: [{ type: "FORBIDDEN" }] }));
  await assert.rejects(fetchRepoIndex(env({}), NOW));
});

test("a PR's summary says its state, open or not, and null when there is no such PR", async () => {
  const node = { number: 7, title: "Add retries", state: "MERGED", isDraft: false, updatedAt: "2026-11-01T00:00:00Z",
    url: "https://github.com/acme/api/pull/7", author: { login: "alex" }, repository: { nameWithOwner: "acme/api" } };
  assert.deepEqual(summaryOf(node), {
    repo: "acme/api", number: 7, title: "Add retries", state: "merged", author: "alex",
    updatedAt: "2026-11-01T00:00:00Z", url: "https://github.com/acme/api/pull/7",
  });
  assert.equal(summaryOf({ ...node, state: "OPEN", isDraft: true }).state, "draft");
  assert.equal(summaryOf({ ...node, state: "CLOSED", author: null }).author, null);
  const asked = mockGraphql((_query, variables) => (variables.number === 7
    ? { data: { repository: { pullRequest: node } } }
    : { data: { repository: { pullRequest: null } }, errors: [{ type: "NOT_FOUND" }] }));
  assert.equal((await pullRequestSummary("acme/api", 7, env({})))?.state, "merged");
  assert.deepEqual(asked[0].variables, { owner: "acme", name: "api", number: 7 });
  assert.equal(await pullRequestSummary("acme/api", 8, env({})), null);
});
