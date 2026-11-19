import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { test, vi } from "vitest";
import { installationToken, TOKEN_MARGIN_MS } from "../../src/read-app.ts";
import type { Env } from "../../src/env.ts";
import { readChecks, readPullRequests, searchListings } from "../../src/github.ts";
import { prId, repoOf } from "../../src/ids.ts";
import {
  type Asked,
  fakeFetch,
  fieldsNamed,
  type GraphqlRequest,
  rootOf,
  searchOf,
  stubFetch,
} from "../support/fake-fetch.ts";
import { prNode } from "../support/pr-node.ts";

const { privateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

const HOUR = 3_600_000;

test("a token is minted once and kept until five minutes before it expires", async () => {
  const app = { id: "app-cache", key: privateKey };
  const expiresAt = Date.parse("2026-11-16T10:00:00Z");
  const { fetch: fetcher, asked } = fakeFetch(() =>
    Response.json({ token: `t${asked.length}`, expires_at: new Date(expiresAt).toISOString() }),
  );
  const early = expiresAt - HOUR;
  const [first, second] = await Promise.all([
    installationToken(app, 11, fetcher, early),
    installationToken(app, 11, fetcher, early),
  ]);
  assert.deepEqual([first, second, asked.length], ["t1", "t1", 1]);
  assert.equal(await installationToken(app, 11, fetcher, expiresAt - TOKEN_MARGIN_MS - 1), "t1");
  assert.equal(await installationToken(app, 11, fetcher, expiresAt - TOKEN_MARGIN_MS + 1), "t2");
  assert.equal(
    await installationToken(app, 12, fetcher, early),
    "t3",
    "each installation has its own",
  );
});

test("a refused mint is not kept: the next read asks again", async () => {
  const app = { id: "app-refused", key: privateKey };
  const now = Date.parse("2026-11-16T09:00:00Z");
  const { fetch: fetcher, asked } = fakeFetch(() =>
    asked.length === 1
      ? new Response(null, { status: 403 })
      : Response.json({ token: "t", expires_at: new Date(now + HOUR).toISOString() }),
  );
  await assert.rejects(installationToken(app, 11, fetcher, now));
  assert.equal(await installationToken(app, 11, fetcher, now), "t");
});

/** acme and octocat have the App on all their repos; partly on some; other has none. */
const INSTALLED = [
  { id: 11, account: { login: "acme", type: "Organization" }, repository_selection: "all" },
  { id: 12, account: { login: "octocat", type: "User" }, repository_selection: "all" },
  { id: 13, account: { login: "partly", type: "Organization" }, repository_selection: "selected" },
];

/**
 * GitHub with the read App installed as `INSTALLED`; `refused` installations get no token. `answer` answers each GraphQL
 * request, given the token it came with.
 */
function gitHub(
  answer: (graphql: GraphqlRequest, token: string) => unknown,
  refused: number[] = [],
): Asked[] {
  return stubFetch((call) => {
    if (call.url.includes("/app/installations?")) {
      return Response.json(INSTALLED);
    }
    const minted = /\/app\/installations\/(\d+)\/access_tokens$/.exec(call.url);
    if (minted) {
      const id = Number(minted[1]);
      return refused.includes(id)
        ? new Response(null, { status: 403 })
        : Response.json(
            { token: `inst-${id}`, expires_at: new Date(Date.now() + HOUR).toISOString() },
            { status: 201 },
          );
    }
    if (call.graphql) {
      return Response.json(answer(call.graphql, call.token));
    }
    return new Response(null, { status: 404 });
  });
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
function nodes(graphql: GraphqlRequest): unknown {
  const viewerOnly = !graphql.spreads.has("Fields") && graphql.spreads.has("Viewer");
  const node = viewerOnly
    ? {
        viewerDidAuthor: false,
        repository: { viewerDefaultMergeMethod: "MERGE" },
        files: { nodes: [] },
        reviewThreads: { nodes: [] },
      }
    : prNode();
  return {
    data: Object.fromEntries(graphql.fields.map((field) => [field.alias, { pullRequest: node }])),
  };
}

/** The PRs each detail query asked for, by the token it went with. */
function detailReads(calls: Asked[]): string[] {
  return calls
    .filter((call) => call.graphql?.spreads.has("Fields"))
    .map(
      (call) =>
        `${call.token}:${(call.graphql?.fields ?? [])
          .map((field) => String(field.args.owner))
          .sort()
          .join(",")}`,
    )
    .sort();
}

/** A checks-only read: its PRs select their fields directly, with no fragment. */
const isChecksRead = (call: Asked) =>
  fieldsNamed(call.graphql?.fields ?? [], "pullRequest").some((pr) => pr.spreads.length === 0);
const listing = (repo: string, number: number) => ({
  number,
  updatedAt: "2026-11-06T09:30:00Z",
  author: { __typename: "User" },
  repository: { nameWithOwner: repo },
  commits: { nodes: [] },
});

test("each installation reads its owner's PRs; the rest, and the viewer's own fields, go as the owner", async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  const calls = gitHub(nodes);
  const read = await readPullRequests(REFS, env(), new Set(), async () => new Map());
  assert.deepEqual(detailReads(calls), ["inst-11:acme", "inst-12:octocat", "owner:other,partly"]);
  const viewer = calls.filter((call) => call.graphql?.spreads.has("Viewer"));
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
  const checks = calls.filter(isChecksRead);
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

test("the owners without an installation read with GITHUB_READ_TOKEN when it is set", async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  const calls = gitHub(nodes);
  await readPullRequests(
    REFS,
    env({ GITHUB_READ_TOKEN: "reader" }),
    new Set(),
    async () => new Map(),
  );
  assert.deepEqual(detailReads(calls), ["inst-11:acme", "inst-12:octocat", "reader:other,partly"]);
});

test("an installation GitHub won't give a token reads as before", async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  const calls = gitHub(nodes, [12]);
  await readPullRequests(REFS, env(), new Set(), async () => new Map());
  assert.deepEqual(detailReads(calls), ["inst-11:acme", "owner:octocat,other,partly"]);
});

test("each installation searches, the owner's token searches the other owners, and the answers merge", async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  const calls = gitHub((graphql, token) => {
    const q = String(graphql.variables.q ?? "");
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
  const searches = calls.filter((call) => call.graphql);
  assert.equal(searches.length, 9, "three searches each, for two installations and the owner");
  for (const call of searches) {
    const q = searchOf(call);
    assert.equal(q.includes("-org:acme -user:octocat"), call.token === "owner", q);
    assert.ok(!q.includes("partly"), q);
  }
  assert.deepEqual(
    [...found.values()].map((one) => [one.repo, one.number, one.reviewedOnly]),
    [
      ["other/lib", 3, true],
      ["acme/app", 1, false],
    ],
  );
});

test("unset, and on the hosted Worker, the read App is never asked and every read goes as before", async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  for (const vars of [
    { GITHUB_READ_APP_ID: undefined },
    { SIGNED_IN_USER_ID: "1" },
    { HOSTED: "on" },
  ]) {
    const calls = gitHub((graphql) =>
      rootOf(graphql) === "search"
        ? { data: { search: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } }
        : nodes(graphql),
    );
    await readPullRequests(REFS, env(vars), new Set(), async () => new Map());
    await readChecks(REFS, env(vars));
    await searchListings(env(vars));
    assert.ok(!calls.some((call) => call.url.includes("/app/")), JSON.stringify(vars));
    assert.deepEqual(new Set(calls.map((call) => call.token)), new Set(["owner"]));
    assert.equal(calls.filter((call) => call.graphql?.spreads.has("Viewer")).length, 1);
  }
});
