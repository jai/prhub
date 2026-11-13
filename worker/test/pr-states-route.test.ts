// POST /prs/states is read by the PR index (its own cache of .policy.yml and memberships), and says what it spent.
import assert from "node:assert/strict";
import test from "node:test";
import { statesRoute } from "../src/pr-states.ts";

const post = (body: unknown) => new Request("https://w/prs/states", { method: "POST", body: JSON.stringify(body) });

test("the states come back with the GitHub calls they cost, and a refusal is a 502 with GitHub's words", async () => {
  const asked: string[][] = [];
  const answered = await statesRoute(post({ refs: ["acme/api#7"] }), null, async (refs) => {
    asked.push(refs);
    return { answer: { states: {}, unanswered: [] }, githubCalls: 3 };
  });
  assert.deepEqual(asked, [["acme/api#7"]]);
  assert.equal(answered.headers.get("Server-Timing"), 'github;desc="github calls";dur=3');
  assert.deepEqual(await answered.json(), { states: {}, unanswered: [] });
  const refused = await statesRoute(post({ refs: ["acme/api#7"] }), null,
    async () => ({ failure: "HTTP 429", githubCalls: 1 }));
  assert.equal(refused.status, 502);
  assert.deepEqual(await refused.json(), { reason: "HTTP 429" });
  assert.equal((await statesRoute(post({ nope: 1 }), null, async () => assert.fail("not read"))).status, 400);
});
