import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { FAILURE_KEPT_MS, isStaleFailure, runAiJob } from "../src/ai-run.ts";
import { runOnSubscription } from "../src/agent-container.ts";
import { prDiff } from "../src/ask-subscription.ts";
import type { Env } from "../src/env.ts";
import { liveDiff, revisionFrom } from "../src/github.ts";
import { isRevisionOf, parseSha, revisionOf, type Sha } from "../src/ids.ts";
import { aiKey, type AiJob } from "../src/models.ts";
import { type LiveRead, serveVersioned, storeDiff, VERSION_METADATA } from "../src/versioned.ts";

const OLD = "a".repeat(40) as Sha;
const NEW = "b".repeat(40) as Sha;
const OLD_REVISION = revisionOf(OLD, "main");
const NEW_REVISION = revisionOf(NEW, "main");

interface Put { key: string; value: string; version: string | undefined }

/** An R2 bucket in memory: what was put, and with which version. */
function fakeStore(held: Record<string, { body: string; version?: string }> = {}) {
  const puts: Put[] = [];
  const store = {
    puts,
    async get(key: string) {
      return held[key] ? { body: held[key].body } : null;
    },
    async head(key: string) {
      return held[key] ? { customMetadata: held[key].version ? { [VERSION_METADATA]: held[key].version } : {} } : null;
    },
    async put(key: string, value: ArrayBuffer | string,
      options?: { customMetadata?: Record<string, string> }) {
      const text = typeof value === "string" ? value : new TextDecoder().decode(value);
      puts.push({ key, value: text, version: options?.customMetadata?.[VERSION_METADATA] });
      held[key] = { body: text, version: options?.customMetadata?.[VERSION_METADATA] };
      return null;
    },
  };
  return store;
}

function live(body: string, version: string | null, status = 200): () => Promise<LiveRead> {
  return async () => ({ response: new Response(body, { status }), version });
}

/** `serveVersioned` with its deferred writes run before the test looks. */
async function serve(store: ReturnType<typeof fakeStore>, requested: string, load: () => Promise<LiveRead>) {
  const pending: Promise<unknown>[] = [];
  const response = await serveVersioned(store as never, `k/${requested}`, requested, "text/plain", load,
    (promise) => pending.push(promise));
  await Promise.all(pending);
  return { status: response.status, body: await response.text() };
}

test("a commit is 40 lowercase hex characters, and a revision is of its head", () => {
  assert.equal(parseSha(OLD), OLD);
  assert.equal(parseSha("A".repeat(40)), null);
  assert.equal(parseSha("a".repeat(39)), null);
  assert.equal(parseSha(42), null);
  assert.ok(isRevisionOf(OLD_REVISION, OLD));
  assert.ok(!isRevisionOf(OLD_REVISION, NEW));
});

test("a diff read after the head moved on is answered but not kept under the old revision", async () => {
  const store = fakeStore();
  const answer = await serve(store, OLD_REVISION, live("new diff", NEW_REVISION));
  assert.deepEqual(answer, { status: 200, body: "new diff" });
  assert.deepEqual(store.puts, []);
});

test("a live read of the revision asked for is kept under it, and answers from R2 after that", async () => {
  const store = fakeStore();
  await serve(store, OLD_REVISION, live("old diff", OLD_REVISION));
  assert.deepEqual(store.puts, [{ key: `k/${OLD_REVISION}`, value: "old diff", version: OLD_REVISION }]);
  const again = await serve(store, OLD_REVISION, () => assert.fail("R2 has it"));
  assert.equal(again.body, "old diff");
});

test("a read whose version can't be told, or that GitHub refused, is never kept", async () => {
  const store = fakeStore();
  assert.equal((await serve(store, OLD_REVISION, live("diff", null))).body, "diff");
  assert.equal((await serve(store, OLD_REVISION, live("gone", OLD_REVISION, 404))).status, 404);
  assert.deepEqual(store.puts, []);
});

test("the index marks a diff ready only from a copy known to be of the row's revision", async () => {
  const key = `k/${OLD_REVISION}`;
  const verified = fakeStore({ [key]: { body: "old diff", version: OLD_REVISION } });
  assert.equal(await storeDiff(verified as never, key, OLD_REVISION, () => assert.fail("R2 has it")), "ready");

  // A copy from before the check, read again: the head has moved, so it stays pending and nothing is written.
  const legacy = fakeStore({ [key]: { body: "new diff" } });
  assert.equal(await storeDiff(legacy as never, key, OLD_REVISION, live("new diff", NEW_REVISION)), "pending");
  assert.deepEqual(legacy.puts, []);

  const fresh = fakeStore();
  assert.equal(await storeDiff(fresh as never, key, OLD_REVISION, live("old diff", OLD_REVISION)), "ready");
  assert.deepEqual(fresh.puts, [{ key, value: "old diff", version: OLD_REVISION }]);
});

test("too large is said only of the row's own revision", async () => {
  const key = `k/${OLD_REVISION}`;
  assert.equal(await storeDiff(fakeStore() as never, key, OLD_REVISION, live("", OLD_REVISION, 406)), "too_large");
  assert.equal(await storeDiff(fakeStore() as never, key, OLD_REVISION, live("", NEW_REVISION, 406)), "pending");
});

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

/** GitHub with the PR at `head`: its diff, and its REST answer. Anything else asked for is recorded. */
function gitHubAt(head: string, others: string[] = []): void {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    const accept = new Headers(init?.headers).get("Accept") ?? "";
    if (url === "https://api.github.com/repos/acme/app/pulls/7") {
      return accept.includes("diff")
        ? new Response("diff --git a/x b/x\n")
        : Response.json({ title: "T", body: "", head: { sha: head }, base: { ref: "main" } });
    }
    others.push(url);
    return new Response("not here", { status: 500 });
  }) as typeof fetch;
}

test("a live diff says the revision GitHub is at once it has been read", async () => {
  gitHubAt(NEW);
  const read = await liveDiff("acme/app", 7, { GITHUB_TOKEN: "t" } as Env);
  assert.equal(read.version, NEW_REVISION);
  assert.equal(await read.response.text(), "diff --git a/x b/x\n");
  assert.equal(revisionFrom({ head: { sha: "nope" }, base: { ref: "main" } }), null);
});

test("key lines for a head the PR has moved on from are never stored under that head", async () => {
  const others: string[] = [];
  gitHubAt(NEW, others);
  const store = fakeStore();
  const job: AiJob = { kind: "key_lines", repo: "acme/app", number: 7, head: OLD, context: 3 };
  const ready = await runAiJob(job, { GITHUB_TOKEN: "t", ANTHROPIC_API_KEY: "k" } as Env, store as never);
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
        return Response.json({ subtype: "success", output: { items: [] }, model: "claude-sonnet-5-5",
          tokens: { input: 10, output: 2 }, costUsd: 0.0123 });
      },
    }),
  } as unknown as Env["AGENT"];
  const store = fakeStore();
  const job: AiJob = { kind: "key_lines", repo: "acme/app", number: 7, head: NEW, context: 0 };
  await runAiJob(job, { GITHUB_TOKEN: "t", ANTHROPIC_API_KEY: "k", CLAUDE_CODE_OAUTH_TOKEN: "oat", AGENT: agent } as Env,
    store as never);
  assert.equal(asked.length, 1);
  assert.equal(asked[0].model, "claude-sonnet-5-5");
  assert.equal((asked[0].schema as { type: string }).type, "object");
  assert.equal("$schema" in (asked[0].schema as object), false, "Claude Code rejects a $schema it does not know");
  const stored = JSON.parse(store.puts[0].value) as { items: unknown[]; costCents: number; model: string };
  assert.deepEqual(stored.items, []);
  assert.equal(stored.costCents, 1.23);
  assert.deepEqual(others, [], "the API was never asked");
});

test("a stored failure is shown for ten minutes, then the next ask makes the answer again", () => {
  const failed = JSON.stringify({ error: "Error: 400 credit balance is too low" });
  const storedAt = new Date("2026-11-11T06:00:00Z");
  assert.equal(isStaleFailure(failed, storedAt, storedAt.getTime() + FAILURE_KEPT_MS - 1), false);
  assert.equal(isStaleFailure(failed, storedAt, storedAt.getTime() + FAILURE_KEPT_MS), true);
  assert.equal(isStaleFailure(JSON.stringify({ items: [] }), storedAt, storedAt.getTime() + 86_400_000), false,
    "an answer is kept");
});

test("a container that is not ready yet is asked again, and its last words are the failure", async () => {
  const answers = [
    new Response("There is no Container instance available at this time.", { status: 503 }),
    Response.json({ error: "Claude Code process exited with code 143" }, { status: 500 }),
    Response.json({ subtype: "success", output: { items: [] }, model: "m", tokens: { input: 1, output: 1 }, costUsd: 0 }),
  ];
  let dropped = false;
  const agent = { idFromName: (name: string) => name, get: () => ({ fetch: async () => {
    if (!dropped) {
      dropped = true;
      throw new Error("Network connection lost.");
    }
    return answers.shift()!;
  } }) };
  const env = { CLAUDE_CODE_OAUTH_TOKEN: "oat", AGENT: agent } as unknown as Env;
  const answer = await runOnSubscription("s", "p", { type: "object" }, { model: "m" as never, effort: "high" }, env,
    async () => {});
  assert.deepEqual(answer.output, { items: [] });
  assert.equal(dropped, true, "a dropped connection went again too");
  const never = { idFromName: (name: string) => name, get: () => ({ fetch: async () => new Response("busy") }) };
  await assert.rejects(runOnSubscription("s", "p", {}, { model: "m" as never, effort: "high" },
    { ...env, AGENT: never } as unknown as Env, async () => {}), /The AI container failed: busy/);
});

test("Ask's diff is the PR's at the question's head, and none once the PR has moved past it", async () => {
  gitHubAt(NEW);
  assert.equal(await prDiff("acme/app" as never, 7, NEW, { GITHUB_TOKEN: "t" } as Env), "diff --git a/x b/x\n");
  assert.equal(await prDiff("acme/app" as never, 7, OLD, { GITHUB_TOKEN: "t" } as Env), "");
});
