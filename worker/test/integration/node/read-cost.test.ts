// Full PR reads through policy evaluation and membership caching.
import assert from "node:assert/strict";
import { afterEach, test, vi } from "vitest";
import { readPullRequests } from "../../../src/github.ts";
import { memoryCache } from "../../../src/policy-github.ts";
import { env, ref, stubGitHub } from "../../support/read-cost-responses.ts";

const noTickets = async () => new Map();
const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

test("a full read of one dirty PR costs a GraphQL query plus .policy.yml and a membership on a cold cache", async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
  const calls = stubGitHub();
  const cache = memoryCache();
  const read = await readPullRequests([ref(7)], env, new Set(), noTickets, cache);
  assert.equal(read.get(ref(7).id)?.people, "APPROVED", "sam is in acme/backend and approved");
  assert.deepEqual(
    calls.map((call) => call.kind),
    ["graphql", "policy", "membership"],
  );

  calls.length = 0;
  await readPullRequests([ref(7)], env, new Set(), noTickets, cache);
  assert.deepEqual(
    calls.map((call) => call.kind),
    ["graphql"],
    "within their TTLs the answers are cached",
  );
});

test("past their TTLs the answers are asked again with their ETags, and GitHub's 304s cost nothing", async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: Date.parse("2026-11-16T09:00:00Z") });
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
    { kind: "graphql", counted: true },
    { kind: "policy", counted: false },
    { kind: "membership", counted: false },
  ]);
});
