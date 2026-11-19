import assert from "node:assert/strict";
import { test } from "vitest";
import type { Env } from "../../src/env.ts";
import { reportedLimitsOf } from "../../src/limit-enforcement.ts";
import { LimitName, limitsOf, rateWindowOf } from "../../src/limits.ts";

test("bad limit config goes to /events once per isolate, as limits_config_error", () => {
  const recorded: string[] = [];
  const index = {
    record: async (kind: string) => {
      recorded.push(kind);
    },
  };
  const env = {
    LIMIT_WRITES_PER_MINUTE: "lots",
    PR_INDEX: { idFromName: (name: string) => name, get: () => index },
  } as unknown as Env;
  const waited: Promise<unknown>[] = [];
  const waitUntil = (promise: Promise<unknown>) => waited.push(promise);
  reportedLimitsOf(env, waitUntil);
  reportedLimitsOf(env, waitUntil);
  assert.deepEqual(recorded, ["limits_config_error"]);
  assert.equal(
    rateWindowOf(limitsOf(env), LimitName.WritesPerMinute),
    null,
    "the self-hosted default serves",
  );
});
