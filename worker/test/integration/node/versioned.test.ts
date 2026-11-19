import assert from "node:assert/strict";
import { afterEach, test } from "vitest";
import { repoOf, type Sha } from "../../../src/ids.ts";
import { runAiJob } from "../../../src/ai-run.ts";
import type { Env } from "../../../src/env.ts";
import { aiKey, type AiJob } from "../../../src/models.ts";
import { fakeStore, gitHubAt } from "../../support/versioned-responses.ts";

const OLD = "a".repeat(40) as Sha;
const NEW = "b".repeat(40) as Sha;
const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});
const SUMMARY = {
  risk: "low",
  riskWhy: "Small and tested.",
  points: ["One", "Two", "Three", "Four", "Five", "Six"],
  bugs: [{ path: "x", line: 99, side: "RIGHT", why: "Off by one." }],
  slop: { isSlop: false, tells: ["ignored"] },
};

test("key lines for a head the PR has moved on from are never stored under that head", async () => {
  const others: string[] = [];
  gitHubAt(NEW, others);
  const store = fakeStore();
  const job: AiJob = {
    kind: "key_lines",
    repo: repoOf("acme/app"),
    number: 7,
    head: OLD,
    context: 3,
  };
  const ready = await runAiJob(
    job,
    { GITHUB_TOKEN: "t", ANTHROPIC_API_KEY: "k" } as Env,
    store as never,
  );
  assert.equal(ready, false);
  assert.equal(store.puts.length, 1);
  assert.equal(store.puts[0].key, aiKey(job));
  const stored = JSON.parse(store.puts[0].value) as Record<string, unknown>;
  assert.deepEqual(Object.keys(stored), ["error", "moved"]);
  assert.equal(stored.moved, true, "the app asks again at the newest commit");
  assert.match(String(stored.error), /moved on/);
  assert.deepEqual(others, [], "no model was asked");
});

test("on the subscription, key lines come from the Agent SDK container, never the API", async () => {
  const others: string[] = [];
  gitHubAt(NEW, others);
  const asked: Record<string, unknown>[] = [];
  const agent = {
    idFromName: (name: string) => name,
    get: () => ({
      fetch: async (_url: string, init: RequestInit) => {
        asked.push(JSON.parse(String(init.body)) as Record<string, unknown>);
        return Response.json({
          subtype: "success",
          output: { items: [], summary: SUMMARY },
          model: "claude-sonnet-5-5",
          tokens: { input: 10, output: 2 },
          costUsd: 0.0123,
        });
      },
    }),
  } as unknown as Env["AGENT"];
  const store = fakeStore();
  const job: AiJob = {
    kind: "key_lines",
    repo: repoOf("acme/app"),
    number: 7,
    head: NEW,
    context: 0,
  };
  await runAiJob(
    job,
    {
      GITHUB_TOKEN: "t",
      ANTHROPIC_API_KEY: "k",
      CLAUDE_CODE_OAUTH_TOKEN: "oat",
      AGENT: agent,
    } as Env,
    store as never,
  );
  assert.equal(asked.length, 1);
  assert.equal(asked[0].model, "claude-sonnet-5-5");
  assert.equal((asked[0].schema as { type: string }).type, "object");
  assert.equal(
    "$schema" in (asked[0].schema as object),
    false,
    "Claude Code rejects a $schema it does not know",
  );
  const stored = JSON.parse(store.puts[0].value) as {
    items: unknown[];
    costCents: number;
    model: string;
  };
  assert.deepEqual(stored.items, []);
  assert.equal(stored.costCents, 1.23);
  const summary = (
    stored as unknown as {
      summary: { points: string[]; bugs: unknown[]; risk: string; slop: unknown };
    }
  ).summary;
  assert.equal(summary.risk, "low");
  assert.equal(summary.points.length, 5, "five points at most");
  assert.deepEqual(summary.bugs, [], "a bug at a line the diff doesn't show is dropped");
  assert.deepEqual(summary.slop, { isSlop: false, tells: [] }, "no tells when it isn't slop");
  assert.deepEqual(others, [], "the API was never asked");
});
