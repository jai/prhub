import assert from "node:assert/strict";
import test from "node:test";
import type { AskChat } from "../src/ask-chat.ts";
import {
  acceptAsk, ASK_HANDOVER_MS, askPr, askView, type AskIntake, createAskTables, drainAsks, NOT_HANDED_OVER,
  type QueuedAsk, queueAsk, rememberChat, withQueued,
} from "../src/ask-queue.ts";
import type { RepoFullName, Sha } from "../src/ids.ts";
import { memorySql } from "./memory-sql.ts";

const HEAD = "a".repeat(40) as Sha;
const REPO = "acme/api" as RepoFullName;
const PR = askPr(REPO, 7);

function question(id: string, words: string, at = 1_000): QueuedAsk {
  return {
    id, repo: REPO, number: 7, input: { question: words, head: HEAD, anchor: null },
    choice: { model: "claude-haiku-5-5", effort: "high" }, at, error: null,
  };
}

const ANSWERED: AskChat = {
  messages: [
    { id: "m1", role: "you", text: "What does it change?", anchor: null },
    { id: "m2", role: "agent", text: "The retry.", anchor: null },
  ],
  isWorking: false, activity: null, problem: null, costCents: 3, model: "claude-haiku-5-5", effort: "high",
};

function queue() {
  const sql = memorySql();
  createAskTables(sql);
  return sql;
}

/** An intake whose storage answers at once; `calls` says what the route did, in order. */
function intake(sql = queue(), claim: "go" | "busy" | "done" = "go") {
  const calls: string[] = [];
  const answer: AskIntake = {
    claim: async (receipt) => { calls.push(`claim ${receipt}`); return claim; },
    finish: async (receipt, sent) => { calls.push(`finish ${receipt} ${sent}`); },
    limited: async () => { calls.push("limited"); return null; },
    queue: async (stored) => {
      calls.push(stored ? `queue ${stored.id}` : "read");
      if (stored) {
        queueAsk(sql, stored);
      }
      return askView(sql, PR);
    },
    busy: () => new Response(null, { status: 503 }),
  };
  return { answer, calls, sql };
}

test("a question is answered 202 once it is stored, with the chat so far and the question at its end, working", async () => {
  const { answer, calls, sql } = intake();
  rememberChat(sql, PR, ANSWERED, 500);
  const response = await acceptAsk(answer, question("ref-1", "Is it tested?"), "ask:acme/api#7:ref-1");
  assert.equal(response.status, 202);
  const chat = await response.json() as AskChat;
  assert.deepEqual(chat.messages.map((message) => message.text), ["What does it change?", "The retry.", "Is it tested?"]);
  assert.equal(chat.isWorking, true);
  assert.equal(chat.problem, null);
  assert.deepEqual(calls, ["claim ask:acme/api#7:ref-1", "limited", "queue ref-1", "finish ask:acme/api#7:ref-1 true"]);
});

test("the answer never waits on the handover: a question the agent takes a minute to get still answers at once", async () => {
  const { answer, sql } = intake();
  const started = Date.now();
  const response = await acceptAsk(answer, question("ref-1", "Is it tested?"), null);
  assert.equal(response.status, 202);
  assert.ok(Date.now() - started < 500);
  let handedOver = false;
  const slow = drainAsks(sql, () => new Promise((resolve) => setTimeout(() => { handedOver = true; resolve(null); }, 50)));
  assert.equal(handedOver, false, "the route returned before the handover began");
  await slow;
  assert.equal(handedOver, true);
  assert.deepEqual(askView(sql, PR).queued, []);
});

test("a repeat of the same question is the one already stored: nothing is queued twice", async () => {
  const { answer, calls, sql } = intake(queue(), "done");
  queueAsk(sql, question("ref-1", "Is it tested?"));
  const response = await acceptAsk(answer, question("ref-1", "Is it tested?"), "ask:acme/api#7:ref-1");
  assert.equal(response.status, 202);
  assert.deepEqual(calls, ["claim ask:acme/api#7:ref-1", "read"]);
  assert.equal(askView(sql, PR).queued.length, 1);
});

test("a copy already being stored is busy, and a refused one leaves no receipt", async () => {
  assert.equal((await acceptAsk(intake(queue(), "busy").answer, question("r", "q"), "ask:x:r")).status, 503);
  const refused = intake();
  refused.answer.limited = async () => new Response(null, { status: 429 });
  assert.equal((await acceptAsk(refused.answer, question("r", "q"), "ask:x:r")).status, 429);
  assert.deepEqual(refused.calls, ["claim ask:x:r", "finish ask:x:r false"]);
  assert.deepEqual(askView(refused.sql, PR).queued, []);
});

test("questions go to the agent one at a time, oldest first, and a failed one stays with why", async () => {
  const sql = queue();
  queueAsk(sql, question("b", "Second", 2_000));
  queueAsk(sql, question("a", "First", 1_000));
  const order: string[] = [];
  await drainAsks(sql, async (ask) => {
    order.push(ask.input.question);
    return ask.id === "b" ? "The Ask App isn't installed on acme/api." : null;
  });
  assert.deepEqual(order, ["First", "Second"]);
  const [failed] = askView(sql, PR).queued;
  assert.equal(failed?.error, "The Ask App isn't installed on acme/api.");
  assert.equal(failed?.input.question, "Second");
  queueAsk(sql, question("c", "Second", 3_000));
  assert.deepEqual(askView(sql, PR).queued.map((ask) => ask.id), ["c"], "Try again replaces the failed question");
});

test("the chat shows a failed question with why, and stops working", () => {
  const failed = { ...question("a", "Is it tested?"), error: "The AI couldn't be reached. Try again." };
  const chat = withQueued(ANSWERED, [failed], 2_000);
  assert.equal(chat.messages.at(-1)?.text, "Is it tested?");
  assert.equal(chat.isWorking, false);
  assert.equal(chat.problem, "The AI couldn't be reached. Try again.");
});

test("a question never handed over says so after a while, rather than working for ever", () => {
  const chat = withQueued(ANSWERED, [question("a", "Is it tested?", 1_000)], 1_000 + ASK_HANDOVER_MS + 1);
  assert.equal(chat.isWorking, false);
  assert.equal(chat.problem, NOT_HANDED_OVER);
});

test("a question the agent's chat already ends with is not shown twice", () => {
  const asked = { ...ANSWERED, messages: [...ANSWERED.messages, { id: "m3", role: "you" as const, text: "Is it tested?", anchor: null }], isWorking: true };
  const chat = withQueued(asked, [question("a", "Is it tested?")], 2_000);
  assert.equal(chat.messages.length, 3);
  assert.equal(chat.isWorking, true);
});

test("a question about a line names it, and a chat with nothing yet starts empty", () => {
  const ask = question("a", "Why?");
  ask.input.anchor = { path: "src/retry.ts", line: 12, side: "RIGHT" };
  const chat = withQueued(null, [ask], 2_000);
  assert.deepEqual(chat.messages,
    [{ id: "queued:a", role: "you", text: "Why?", anchor: "src/retry.ts:12", side: "RIGHT" }]);
  assert.equal(chat.isWorking, true);
});
