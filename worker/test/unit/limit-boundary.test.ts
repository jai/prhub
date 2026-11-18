import assert from "node:assert/strict";
import { test } from "node:test";
import type { Env } from "../../src/env.ts";
import { personLimitAnswer } from "../../src/limit-enforcement.ts";
import { LimitName } from "../../src/limits.ts";
import { pullRequestOfKey } from "../../src/retention.ts";

test("a limit that is off never reaches the index", async () => {
  const env = {
    PR_INDEX: { idFromName: () => assert.fail("no count"), get: () => assert.fail("no count") },
  } as unknown as Env;
  assert.equal(
    await personLimitAnswer(
      env,
      [LimitName.AskQuestionsPerHour, LimitName.AskQuestionsPerDay],
      null,
    ),
    null,
  );
});

test("each object a PR leaves maps to that PR, under the person's prefix; anything else to none", () => {
  const prefix = "users/4242/";
  assert.equal(pullRequestOfKey(`${prefix}acme/api/7/abc-main.diff`, prefix), "acme/api#7");
  assert.equal(pullRequestOfKey(`${prefix}acme/api/7/detail/v3.json`, prefix), "acme/api#7");
  assert.equal(
    pullRequestOfKey(`${prefix}ai/acme/api/7/${"a".repeat(40)}/key-lines-3.json`, prefix),
    "acme/api#7",
  );
  assert.equal(pullRequestOfKey(`${prefix}ask/acme/api/7.json`, prefix), "acme/api#7");
  assert.equal(
    pullRequestOfKey(`${prefix}ai/api/7/abc.diff`, prefix),
    "ai/api#7",
    "an owner named ai",
  );
  assert.equal(pullRequestOfKey(`${prefix}repos/index.json`, prefix), null);
  assert.equal(
    pullRequestOfKey("users/5151/acme/api/7/abc.diff", prefix),
    null,
    "another person's",
  );
  assert.equal(pullRequestOfKey("pair/abc.json", ""), null);
});
