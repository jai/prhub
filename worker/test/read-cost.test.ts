// What one read costs of the person's GitHub hour, counted at `fetch`: a full read of a dirty PR (`readPullRequests`)
// against a checks-only read (`readChecks`), and the `.policy.yml` answers a 304 renews for nothing.
import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import type { Env } from "../src/env.ts";
import { readChecks, readPullRequests } from "../src/github.ts";
import { prId, type RepoFullName } from "../src/ids.ts";
import { memoryCache } from "../src/policy-github.ts";
import { prNode } from "./pr-node.ts";

const POLICY = `policy:
  approval: [reviewers]
approval_rules:
  - name: reviewers
    requires: { count: 1, teams: [acme/backend] }
`;
const ETAG = '"policy-1"';
const env = { GITHUB_TOKEN: "t", GITHUB_LOGIN: "jai" } as Env;
const repo = "acme/app" as RepoFullName;
const ref = (number: number) => ({ id: prId(repo, number), repo, number });
const approved = { nodes: [{ author: { login: "sam", avatarUrl: "a" }, state: "APPROVED", submittedAt: "2026-11-06T04:00:00Z" }] };
const noTickets = async () => new Map();
const realFetch = globalThis.fetch;

/** Stands in for GitHub; answers each call and keeps what was asked, and whether it would count against the hour. */
function stubGitHub() {
  const calls: { kind: string; counted: boolean }[] = [];
  globalThis.fetch = (async (input: string, init?: RequestInit) => {
    const url = new URL(String(input));
    const etag = (init?.headers as Record<string, string> | undefined)?.["If-None-Match"];
    if (url.pathname === "/graphql") {
      const { query } = JSON.parse(String(init?.body)) as { query: string };
      calls.push({ kind: "graphql", counted: true });
      const aliases = [...query.matchAll(/(p\d+): repository/g)].map((match) => match[1] as string);
      return Response.json({ data: Object.fromEntries(aliases.map((alias, index) =>
        [alias, { pullRequest: prNode({ number: 7 + index, latestReviews: approved }) }])) });
    }
    if (url.pathname.endsWith("/contents/.policy.yml")) {
      calls.push({ kind: "policy", counted: etag !== ETAG });
      return etag === ETAG ? new Response(null, { status: 304 }) : new Response(POLICY, { headers: { ETag: ETAG } });
    }
    if (url.pathname.includes("/teams/")) {
      calls.push({ kind: "membership", counted: etag !== '"team-1"' });
      return etag === '"team-1"' ? new Response(null, { status: 304 })
        : Response.json({ state: "active" }, { headers: { ETag: '"team-1"' } });
    }
    throw new Error(`unexpected ${url}`);
  }) as typeof fetch;
  return calls;
}

afterEach(() => {
  globalThis.fetch = realFetch;
});

test("a full read of one dirty PR costs a GraphQL query plus .policy.yml and a membership on a cold cache", async () => {
  const calls = stubGitHub();
  const cache = memoryCache();
  const read = await readPullRequests([ref(7)], env, new Set(), noTickets, cache);
  assert.equal(read.get(ref(7).id)?.people, "APPROVED", "sam is in acme/backend and approved");
  assert.deepEqual(calls.map((call) => call.kind), ["graphql", "policy", "membership"]);

  calls.length = 0;
  await readPullRequests([ref(7)], env, new Set(), noTickets, cache);
  assert.deepEqual(calls.map((call) => call.kind), ["graphql"], "within their TTLs the answers are cached");
});

test("past their TTLs the answers are asked again with their ETags, and GitHub's 304s cost nothing", async () => {
  const calls = stubGitHub();
  const cache = memoryCache();
  await readPullRequests([ref(7)], env, new Set(), noTickets, cache);
  for (const key of ["policy:acme/app@main", "team:acme/backend:sam"]) {
    cache.set(key, { ...cache.get(key)!, at: 0 });
  }
  calls.length = 0;
  const read = await readPullRequests([ref(7)], env, new Set(), noTickets, cache);
  assert.equal(read.get(ref(7).id)?.people, "APPROVED");
  assert.deepEqual(calls, [
    { kind: "graphql", counted: true }, { kind: "policy", counted: false }, { kind: "membership", counted: false },
  ]);
});

test("one PR GitHub refuses fails only its own part of a checks read", async () => {
  stubGitHub();
  const answered = globalThis.fetch;
  globalThis.fetch = (async (input: string, init?: RequestInit) => {
    const body = await (await answered(input, init)).json() as { data: Record<string, unknown> };
    return Response.json({ data: { ...body.data, p1: null },
      errors: [{ type: "FORBIDDEN", path: ["p1"], message: "SAML enforcement" }] });
  }) as typeof fetch;
  const read = await readChecks([ref(7), ref(8), ref(9)], env);
  assert.equal(read.get(ref(8).id), "error");
  assert.equal(typeof read.get(ref(7).id), "object");
  assert.equal(typeof read.get(ref(9).id), "object");
});

test("a checks-only read of many PRs is one GraphQL query and no REST call", async () => {
  const calls = stubGitHub();
  const read = await readChecks([ref(7), ref(8), ref(9)], env);
  assert.equal(read.size, 3);
  const eight = read.get(ref(8).id);
  assert.equal(typeof eight === "object" ? eight?.mergeStateStatus : eight, "BLOCKED");
  assert.deepEqual(calls.map((call) => call.kind), ["graphql"]);
});
