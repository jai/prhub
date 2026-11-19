import assert from "node:assert/strict";
import { beforeEach, test } from "vitest";
import { askContainer, resetAccounts, subscriptionAccounts } from "../../src/agent-container.ts";
import type { Env } from "../../src/env.ts";

const LIMIT =
  "Claude Code returned an error result: You've hit your weekly limit · resets Nov 21, 3pm (UTC)";

/** A container that answers each account as `answers` says, and keeps which account each run named. */
function world(tokens: string, answers: Record<number, Record<string, unknown>>) {
  const accounts: number[] = [];
  const agent = {
    idFromName: (name: string) => name,
    get: () => ({
      fetch: async (_url: string, init: RequestInit) => {
        const { account } = JSON.parse(String(init.body)) as { account: number };
        accounts.push(account);
        return Response.json(answers[account] ?? { output: "ok" });
      },
    }),
  };
  return { accounts, env: { CLAUDE_CODE_OAUTH_TOKEN: tokens, AGENT: agent } as unknown as Env };
}

beforeEach(() => resetAccounts());

test("the secret holds one token or several, by commas or new lines", () => {
  assert.equal(subscriptionAccounts({ CLAUDE_CODE_OAUTH_TOKEN: "a" }), 1);
  assert.equal(subscriptionAccounts({ CLAUDE_CODE_OAUTH_TOKEN: "a, b\nc" }), 3);
  assert.equal(subscriptionAccounts({ CLAUDE_CODE_OAUTH_TOKEN: undefined }), 0);
});

test("an account at its limit hands the run to the next, which is where the next run starts", async () => {
  const w = world("a,b,c", { 0: { error: LIMIT } });
  assert.deepEqual(await askContainer("/run", {}, w.env, async () => {}), { output: "ok" });
  assert.deepEqual(w.accounts, [0, 1]);
  await askContainer("/run", {}, w.env, async () => {});
  assert.deepEqual(w.accounts, [0, 1, 1], "the spent account is passed over next time");
});

test("each account is tried once; with all spent, the last one's words come back", async () => {
  const w = world("a,b,c", { 0: { error: LIMIT }, 1: { error: LIMIT }, 2: { error: LIMIT } });
  const answer = await askContainer<{ error?: string }>("/run", {}, w.env, async () => {});
  assert.deepEqual(w.accounts, [0, 1, 2]);
  assert.equal(answer.error, LIMIT);
});

test("another failure is the run's own, and no other account is asked", async () => {
  const w = world("a,b", {
    0: { error: "The question names no PR this container can check out." },
  });
  await askContainer("/run", {}, w.env, async () => {});
  assert.deepEqual(w.accounts, [0]);
});
