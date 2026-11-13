// POST /prs/states is read by the PR index (its own cache of .policy.yml and memberships), and says what it spent.
import assert from "node:assert/strict";
import test from "node:test";
import type { Env } from "../src/env.ts";
import type { PrId } from "../src/ids.ts";
import { readStates, statesRoute } from "../src/pr-states.ts";

const post = (body: unknown) => new Request("https://w/prs/states", { method: "POST", body: JSON.stringify(body) });

test("the states come back with the GitHub calls they cost, and a refusal is a 502 with its code and GitHub's words", async () => {
  const asked: string[][] = [];
  const answered = await statesRoute(post({ refs: ["acme/api#7"] }), null, async (refs) => {
    asked.push(refs);
    return { answer: { states: {}, unanswered: [] }, githubCalls: 3 };
  });
  assert.deepEqual(asked, [["acme/api#7"]]);
  assert.equal(answered.headers.get("Server-Timing"), 'github;desc="github calls";dur=3');
  assert.deepEqual(await answered.json(), { states: {}, unanswered: [] });
  const refused = await statesRoute(post({ refs: ["acme/api#7"] }), null,
    async () => ({ failure: { code: "github_rate_limited", message: "GitHub GraphQL answered 429" }, githubCalls: 1 }));
  assert.equal(refused.status, 502);
  assert.deepEqual(await refused.json(), {
    error: { code: "github_rate_limited", message: "GitHub GraphQL answered 429" }, reason: "GitHub GraphQL answered 429",
  }, "a stable code to count by, and the words");
  assert.equal((await statesRoute(post({ nope: 1 }), null, async () => assert.fail("not read"))).status, 400);
});

test("a states answer GitHub cut off is asked again one PR at a time, not a 500", async () => {
  const real = globalThis.fetch;
  const asked: number[] = [];
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const { query } = JSON.parse(String(init?.body)) as { query: string };
    const prs = (query.match(/pullRequest\(/g) ?? []).length;
    asked.push(prs);
    return prs > 1 ? new Response('{"data":{"r0":{"p0":{"title":"Unterminated') : Response.json({ data: { r0: { p0: null } } });
  }) as typeof fetch;
  try {
    const answer = await readStates(["acme/api#7", "acme/api#8"] as PrId[], null,
      { GITHUB_TOKEN: "t", GITHUB_LOGIN: "jai" } as unknown as Env);
    assert.deepEqual(asked, [2, 1, 1], "the whole query once, then each PR");
    assert.equal(Object.keys(answer.states).length + answer.unanswered.length, 2);
  } finally {
    globalThis.fetch = real;
  }
});

test("GitHub's rate limit, its own trouble and any other refusal each have their code", async () => {
  const real = globalThis.fetch;
  const answers = [
    new Response("", { status: 403, headers: { "x-ratelimit-remaining": "0" } }),
    new Response("", { status: 502 }),
    new Response("", { status: 401 }),
  ];
  globalThis.fetch = (async () => answers.shift()!) as unknown as typeof fetch;
  try {
    const env = { GITHUB_TOKEN: "t", GITHUB_LOGIN: "jai" } as unknown as Env;
    for (const code of ["github_rate_limited", "github_unavailable", "github_failed"]) {
      await assert.rejects(readStates(["acme/api#7"] as PrId[], null, env), (error: { code?: string }) => error.code === code);
    }
  } finally {
    globalThis.fetch = real;
  }
});
