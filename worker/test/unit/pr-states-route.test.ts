// POST /prs/states is read by the PR index (its own cache of .policy.yml and memberships), and says what it spent.
import assert from "node:assert/strict";
import { test } from "vitest";
import { prId, repoOf } from "../../src/ids.ts";
import type { Env } from "../../src/env.ts";
import { readStates, statesRoute } from "../../src/pr-states.ts";
import { type Asked, fieldsNamed, stubFetch } from "../support/fake-fetch.ts";

const post = (body: unknown) =>
  new Request("https://w/prs/states", { method: "POST", body: JSON.stringify(body) });

test("the states come back with the GitHub calls they cost, and a refusal is a 502 with its code and GitHub's words", async () => {
  const asked: string[][] = [];
  const answered = await statesRoute(post({ refs: ["acme/api#7"] }), null, async (refs) => {
    asked.push(refs);
    return { answer: { states: {}, unanswered: [] }, githubCalls: 3 };
  });
  assert.deepEqual(asked, [["acme/api#7"]]);
  assert.equal(answered.headers.get("Server-Timing"), 'github;desc="github calls";dur=3');
  assert.deepEqual(await answered.json(), { states: {}, unanswered: [] });
  const refused = await statesRoute(post({ refs: ["acme/api#7"] }), null, async () => ({
    failure: { code: "github_rate_limited", message: "GitHub GraphQL answered 429" },
    githubCalls: 1,
  }));
  assert.equal(refused.status, 502);
  assert.deepEqual(
    await refused.json(),
    {
      error: { code: "github_rate_limited", message: "GitHub GraphQL answered 429" },
      reason: "GitHub GraphQL answered 429",
    },
    "a stable code to count by, and the words",
  );
  assert.equal(
    (await statesRoute(post({ nope: 1 }), null, async () => assert.fail("not read"))).status,
    400,
  );
});

test("a states answer GitHub cut off is asked again one PR at a time, not a 500", async () => {
  const prsOf = (asked: Asked) => fieldsNamed(asked.graphql?.fields ?? [], "pullRequest").length;
  const calls = stubFetch((asked) =>
    prsOf(asked) > 1
      ? new Response('{"data":{"r0":{"p0":{"title":"Unterminated')
      : Response.json({ data: { r0: { p0: null } } }),
  );
  const answer = await readStates(
    [prId(repoOf("acme/api"), 7), prId(repoOf("acme/api"), 8)],
    null,
    {
      GITHUB_TOKEN: "t",
      GITHUB_LOGIN: "jai",
    } as unknown as Env,
  );
  assert.deepEqual(calls.map(prsOf), [2, 1, 1], "the whole query once, then each PR");
  assert.equal(Object.keys(answer.states).length + answer.unanswered.length, 2);
});

test("GitHub's rate limit, its own trouble and any other refusal each have their code", async () => {
  const answers = [
    new Response("", { status: 403, headers: { "x-ratelimit-remaining": "0" } }),
    new Response("", { status: 502 }),
    new Response("", { status: 401 }),
  ];
  stubFetch(() => answers.shift()!);
  const env = { GITHUB_TOKEN: "t", GITHUB_LOGIN: "jai" } as unknown as Env;
  for (const code of ["github_rate_limited", "github_unavailable", "github_failed"]) {
    await assert.rejects(
      readStates([prId(repoOf("acme/api"), 7)], null, env),
      (error: { code?: string }) => error.code === code,
    );
  }
});
