// The server's decisions apart from its HTTP, git and SDK.
import assert from "node:assert/strict";
import { test, vi } from "vitest";
import {
  activityOf,
  askAnswer,
  createLocks,
  createNeeds,
  grantedRepos,
  parseBody,
  runAnswer,
  SeededStore,
  turnKeeper,
  vetQuestion,
} from "../../ask-core.mjs";
import { ACTS, LINEAR_ACTS } from "../../replies.mjs";

test("a body is a JSON object, or refused", () => {
  assert.deepEqual(parseBody('{"a":1}'), { body: { a: 1 } });
  for (const text of ['"not an object"', "[]", "null", "3", '{"not an object"', ""]) {
    assert.equal(typeof parseBody(text).error, "string", text);
  }
});

test("a question names one PR: a scope, owner/name, a number and a full head", () => {
  const good = { scope: "user-1", repo: "acme/api", number: 7, head: "a".repeat(40) };
  assert.equal(vetQuestion(good), null);
  for (const bad of [
    { scope: undefined },
    { scope: "a/b" },
    { repo: "acme" },
    { repo: "../x" },
    { repo: "acme/.." },
    { number: "7" },
    { number: 7.5 },
    { head: "abc" },
    { head: "A".repeat(40) },
  ]) {
    assert.notEqual(vetQuestion({ ...good, ...bad }), null, JSON.stringify(bad));
  }
});

test("the grant keeps only repo names, and is null without a list", () => {
  assert.deepEqual(grantedRepos(["acme/api", "../etc", 3, "Acme/Actions"]), [
    "acme/api",
    "Acme/Actions",
  ]);
  assert.equal(grantedRepos(undefined), null);
  assert.equal(grantedRepos("acme/api"), null);
});

test("a run's answer names the asked model when it ran, and sums its input tokens", () => {
  const answer = runAnswer(
    {
      subtype: "success",
      structured_output: { ok: true },
      modelUsage: { "claude-haiku": {}, "claude-opus": {} },
      usage: {
        input_tokens: 10,
        cache_creation_input_tokens: 5,
        cache_read_input_tokens: 2,
        output_tokens: 7,
      },
      total_cost_usd: 0.25,
    },
    "claude-opus",
  );
  assert.deepEqual(answer, {
    subtype: "success",
    output: { ok: true },
    model: "claude-opus",
    tokens: { input: 17, output: 7 },
    costUsd: 0.25,
  });
  const bare = runAnswer({ subtype: "error", modelUsage: { "claude-haiku": {} } }, "claude-opus");
  assert.equal(bare.model, "claude-haiku", "the model that ran when the asked one didn't");
  assert.deepEqual(bare.tokens, { input: 0, output: 0 });
  assert.equal(bare.output, null);
  assert.equal(bare.costUsd, null);
  assert.equal(runAnswer({}, "claude-opus").model, "claude-opus");
});

test("an ask's answer has both tokens out of every text the agent wrote", () => {
  vi.stubEnv("CLAUDE_CODE_OAUTH_TOKEN", "sk-sub");
  const answer = askAnswer({
    result: { subtype: "success", result: "sk-sub and ghs-x", session_id: "s1" },
    tools: ["Read"],
    draft: {
      event: "COMMENT",
      body: "ghs-x",
      comments: [{ path: "a", line: 1, side: "RIGHT", body: "sk-sub" }],
    },
    actions: [{ kind: "comment", body: "kept as asked" }],
    linear: [{ issue: "ENG-1", body: "ghs-x" }],
    entries: [{ n: 1 }],
    model: "m",
    token: "ghs-x",
  });
  assert.equal(answer.text, "[redacted] and [redacted]");
  assert.equal(answer.draft.body, "[redacted]");
  assert.equal(answer.draft.comments[0].body, "[redacted]");
  assert.equal(answer.linear[0].body, "[redacted]");
  assert.equal(answer.session, "s1");
  assert.deepEqual(answer.entries, [{ n: 1 }]);
  const none = askAnswer({
    result: { result: { not: "text" } },
    draft: null,
    actions: [],
    linear: [],
    model: "m",
    token: null,
  });
  assert.equal(none.text, null);
  assert.equal(none.draft, null);
});

test("a turn keeps the newest draft, and actions and Linear comments up to their caps", () => {
  const { kept, onDraft, onAct, onLinear } = turnKeeper();
  onDraft({ body: "first" });
  onDraft({ body: "second" });
  for (let at = 0; at < ACTS + 2; at++) onAct({ at });
  for (let at = 0; at < LINEAR_ACTS + 2; at++) onLinear({ at });
  assert.deepEqual(kept.draft, { body: "second" });
  assert.equal(kept.actions.length, ACTS);
  assert.deepEqual(kept.actions.at(-1), { at: ACTS - 1 });
  assert.equal(kept.linear.length, LINEAR_ACTS);
});

test("runs on one key take turns, a failure doesn't stop the next, and other keys don't wait", async () => {
  const locked = createLocks();
  const order = [];
  let release;
  const first = locked("a", () =>
    new Promise((done) => (release = done)).then(() => order.push(1)),
  );
  const failing = locked("a", async () => {
    order.push(2);
    throw new Error("boom");
  });
  const third = locked("a", async () => order.push(3));
  await locked("b", async () => order.push("b"));
  assert.deepEqual(order, ["b"], "key b ran while a waited");
  release();
  await first;
  await assert.rejects(failing, /boom/);
  await third;
  assert.deepEqual(order, ["b", 1, 2, 3]);
});

test("the seeded store hands back the Worker's transcript and keeps only the main session's entries", async () => {
  const store = new SeededStore([{ n: 1 }]);
  assert.deepEqual(await store.load({}), [{ n: 1 }]);
  await store.append({}, [{ n: 2 }]);
  await store.append({ subpath: "agent-1" }, [{ n: 3 }]);
  assert.deepEqual(store.entries, [{ n: 1 }, { n: 2 }]);
  assert.equal(await store.load({ subpath: "agent-1" }), null);
  assert.equal(await new SeededStore(undefined).load({}), null);
});

test("what the agent is doing comes from the tool it uses, and names a file alone", () => {
  const using = (name, input) => ({
    type: "assistant",
    message: {
      content: [
        { type: "text", text: "…" },
        { type: "tool_use", name, input },
      ],
    },
  });
  assert.equal(
    activityOf(using("Read", { file_path: "/home/agent/work/u/a/b/7/src/retry.ts" })),
    "Reading retry.ts",
  );
  assert.equal(activityOf(using("Read", { file_path: "/w/.prhub-pr.diff" })), "Reading the diff");
  assert.equal(activityOf(using("Grep", { pattern: "secret" })), "Searching the code");
  assert.equal(activityOf(using("WebFetch", { url: "https://x.test/?q=1" })), "Reading the web");
  assert.equal(activityOf(using("mcp__repo__git", { args: ["log"] })), "Reading the repo");
  for (const quiet of [
    { type: "result" },
    { type: "assistant" },
    { type: "assistant", message: { content: [{ type: "text", text: "Yes." }] } },
  ]) {
    assert.equal(activityOf(quiet), null);
  }
});

test("a tool's question to the Worker is one line of the answer, settled once by its id", async () => {
  const lines = [];
  const needs = createNeeds(1_000, () => "n1");
  const waiting = needs.ask((line) => lines.push(line), { tool: "issue", key: "ENG-12" });
  assert.deepEqual(lines, ['{"need":{"id":"n1","linear":{"tool":"issue","key":"ENG-12"}}}\n']);
  assert.equal(needs.settle("other", { text: "x" }), false, "an id nobody asked settles nothing");
  assert.equal(needs.settle("n1", { text: "ENG-12: Retry", isError: false, extra: 1 }), true);
  assert.deepEqual(await waiting, { text: "ENG-12: Retry", isError: false });
  assert.equal(needs.settle("n1", { text: "again" }), false, "and only once");
});

test("a question the Worker never answers ends as an error, and the turn goes on", async () => {
  vi.useFakeTimers();
  try {
    const needs = createNeeds(45_000, () => "n2");
    const waiting = needs.ask(() => {}, { tool: "search", text: "retry" });
    await vi.advanceTimersByTimeAsync(45_000);
    const answer = await waiting;
    assert.equal(answer.isError, true);
    assert.match(answer.text, /did not answer in time/);
    assert.equal(needs.settle("n2", { text: "late" }), false);
  } finally {
    vi.useRealTimers();
  }
});

test("reading Linear is named in the chat's activity line", () => {
  const use = (name) => ({
    type: "assistant",
    message: { content: [{ type: "tool_use", name, input: { key: "ENG-12" } }] },
  });
  assert.equal(activityOf(use("mcp__prhub__linear_issue")), "Reading Linear");
  assert.equal(activityOf(use("mcp__prhub__linear_search")), "Reading Linear");
});
