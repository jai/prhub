import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { afterEach, test } from "node:test";
import type { Env } from "../../../src/env.ts";
import { readChecks, readPullRequests, searchListings } from "../../../src/github.ts";
import { prId, repoOf } from "../../../src/ids.ts";
import { prNode } from "../../support/pr-node.ts";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

const { privateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

const HOUR = 3_600_000;
/** acme and octocat have the App on all their repos; partly on some; other has none. */
const INSTALLED = [
  { id: 11, account: { login: "acme", type: "Organization" }, repository_selection: "all" },
  { id: 12, account: { login: "octocat", type: "User" }, repository_selection: "all" },
  { id: 13, account: { login: "partly", type: "Organization" }, repository_selection: "selected" },
];

interface Call {
  url: string;
  token: string;
  method: string;
  query: string;
  q: string;
}

/** GitHub with the read App installed as `INSTALLED`; `refused` installations get no token. */
function gitHub(
  answer: (query: string, token: string, q: string) => unknown,
  refused: number[] = [],
): Call[] {
  const calls: Call[] = [];
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    const token = new Headers(init.headers).get("authorization")?.replace("Bearer ", "") ?? "";
    const body =
      typeof init.body === "string"
        ? (JSON.parse(init.body) as { query?: string; variables?: { q?: string } })
        : {};
    const call = {
      url,
      token,
      method: init.method ?? "GET",
      query: body.query ?? "",
      q: body.variables?.q ?? "",
    };
    calls.push(call);
    if (url.includes("/app/installations?")) {
      return Response.json(INSTALLED);
    }
    const minted = /\/app\/installations\/(\d+)\/access_tokens$/.exec(url);
    if (minted) {
      const id = Number(minted[1]);
      return refused.includes(id)
        ? new Response(null, { status: 403 })
        : Response.json(
            { token: `inst-${id}`, expires_at: new Date(Date.now() + HOUR).toISOString() },
            { status: 201 },
          );
    }
    if (url.endsWith("/graphql")) {
      return Response.json(answer(call.query, token, call.q));
    }
    return new Response(null, { status: 404 });
  }) as typeof fetch;
  return calls;
}

let apps = 0;
/** A fresh App id each time: installations and tokens are kept per isolate, per App. */
const env = (vars: Partial<Env> = {}) =>
  ({
    GITHUB_TOKEN: "owner",
    GITHUB_LOGIN: "jai",
    GITHUB_READ_APP_ID: `app-${++apps}`,
    GITHUB_READ_APP_KEY: privateKey,
    ...vars,
  }) as Env;

const ref = (repo: string, number: number) => ({
  id: prId(repoOf(repo), number),
  repo: repoOf(repo),
  number,
});
const REFS = [
  ref("acme/app", 1),
  ref("octocat/tool", 2),
  ref("other/lib", 3),
  ref("partly/web", 4),
];

/** Each alias the query asks for, answered with a PR (or its viewer fields). */
function nodes(query: string): unknown {
  const aliases = [...query.matchAll(/\b(p\d+): repository/g)].map((match) => match[1]);
  const viewerOnly = !query.includes("...Fields") && query.includes("...Viewer");
  const node = viewerOnly
    ? {
        viewerDidAuthor: false,
        repository: { viewerDefaultMergeMethod: "MERGE" },
        files: { nodes: [] },
        reviewThreads: { nodes: [] },
      }
    : prNode();
  return { data: Object.fromEntries(aliases.map((alias) => [alias, { pullRequest: node }])) };
}

/** The PRs each detail query asked for, by the token it went with. */
function detailReads(calls: Call[]): string[] {
  return calls
    .filter((call) => call.url.endsWith("/graphql") && call.query.includes("...Fields"))
    .map(
      (call) =>
        `${call.token}:${[...call.query.matchAll(/owner: "([^"]+)"/g)]
          .map((m) => m[1])
          .sort()
          .join(",")}`,
    )
    .sort();
}
const listing = (repo: string, number: number) => ({
  number,
  updatedAt: "2026-11-06T09:30:00Z",
  author: { __typename: "User" },
  repository: { nameWithOwner: repo },
  commits: { nodes: [] },
});

test("each installation reads its owner's PRs; the rest, and the viewer's own fields, go as the owner", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  const calls = gitHub(nodes);
  const read = await readPullRequests(REFS, env(), new Set(), async () => new Map());
  assert.deepEqual(detailReads(calls), ["inst-11:acme", "inst-12:octocat", "owner:other,partly"]);
  const viewer = calls.filter((call) => call.query.includes("...Viewer"));
  assert.ok(viewer.every((call) => call.token === "owner"));
  assert.ok(
    !calls.some((call) => call.url.includes("/installations/13/")),
    "partly: not on all repos",
  );
  assert.deepEqual(
    REFS.map((one) => read.get(one.id) !== null && read.get(one.id) !== undefined),
    [true, true, true, true],
  );
  const mints = calls.filter((call) => call.url.endsWith("/access_tokens")).length;
  await readChecks(REFS, env({ GITHUB_READ_APP_ID: "app-checks" }));
  await readChecks(REFS, env({ GITHUB_READ_APP_ID: "app-checks" }));
  const checks = calls.filter((call) => call.query.includes("headRefOid updatedAt reviewDecision"));
  assert.deepEqual([...new Set(checks.map((call) => call.token))].sort(), [
    "inst-11",
    "inst-12",
    "owner",
  ]);
  assert.equal(
    calls.filter((call) => call.url.endsWith("/access_tokens")).length - mints,
    2,
    "the second read keeps the tokens",
  );
});

test("the owners without an installation read with GITHUB_READ_TOKEN when it is set", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  const calls = gitHub(nodes);
  await readPullRequests(
    REFS,
    env({ GITHUB_READ_TOKEN: "reader" }),
    new Set(),
    async () => new Map(),
  );
  assert.deepEqual(detailReads(calls), ["inst-11:acme", "inst-12:octocat", "reader:other,partly"]);
});

test("an installation GitHub won't give a token reads as before", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  const calls = gitHub(nodes, [12]);
  await readPullRequests(REFS, env(), new Set(), async () => new Map());
  assert.deepEqual(detailReads(calls), ["inst-11:acme", "owner:octocat,other,partly"]);
});

test("each installation searches, the owner's token searches the other owners, and the answers merge", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  const calls = gitHub((_query, token, q) => {
    const found =
      token === "inst-11" && q.includes("author:jai")
        ? [listing("acme/app", 1)]
        : token === "owner" && q.includes("reviewed-by:jai")
          ? [listing("other/lib", 3)]
          : [];
    return {
      data: { search: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: found } },
    };
  });
  const found = await searchListings(env());
  const searches = calls.filter((call) => call.url.endsWith("/graphql"));
  assert.equal(searches.length, 9, "three searches each, for two installations and the owner");
  for (const call of searches) {
    assert.equal(call.q.includes("-org:acme -user:octocat"), call.token === "owner", call.q);
    assert.ok(!call.q.includes("partly"), call.q);
  }
  assert.deepEqual(
    [...found.values()].map((one) => [one.repo, one.number, one.reviewedOnly]),
    [
      ["other/lib", 3, true],
      ["acme/app", 1, false],
    ],
  );
});

test("unset, and on the hosted Worker, the read App is never asked and every read goes as before", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  for (const vars of [
    { GITHUB_READ_APP_ID: undefined },
    { SIGNED_IN_USER_ID: "1" },
    { HOSTED: "on" },
  ]) {
    const calls = gitHub((query) =>
      query.includes("search(")
        ? { data: { search: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } }
        : nodes(query),
    );
    await readPullRequests(REFS, env(vars), new Set(), async () => new Map());
    await readChecks(REFS, env(vars));
    await searchListings(env(vars));
    assert.ok(!calls.some((call) => call.url.includes("/app/")), JSON.stringify(vars));
    assert.deepEqual(new Set(calls.map((call) => call.token)), new Set(["owner"]));
    assert.equal(calls.filter((call) => call.query.includes("...Viewer")).length, 1);
  }
});
