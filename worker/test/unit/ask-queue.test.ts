import assert from "node:assert/strict";
import { test } from "vitest";
import type { AskChat } from "../../src/ask-chat.ts";
import {
  acceptAsk,
  ASK_HANDOVER_MS,
  type AskIntake,
  type AskView,
  NOT_HANDED_OVER,
  withQueued,
} from "../../src/ask-queue.ts";
import { ANSWERED, question } from "../support/ask-queue-values.ts";

test("the chat shows a failed question with why, and stops working", () => {
  const failed = {
    ...question("a", "Is it tested?"),
    error: "The AI couldn't be reached. Try again.",
  };
  const chat = withQueued(ANSWERED, [failed], 2_000);
  assert.equal(chat.messages.at(-1)?.text, "Is it tested?");
  assert.equal(chat.isWorking, false);
  assert.equal(chat.problem, "The AI couldn't be reached. Try again.");
});

test("a question never handed over says so after a while, rather than working for ever", () => {
  const chat = withQueued(
    ANSWERED,
    [question("a", "Is it tested?", 1_000)],
    1_000 + ASK_HANDOVER_MS + 1,
  );
  assert.equal(chat.isWorking, false);
  assert.equal(chat.problem, NOT_HANDED_OVER);
});

test("a question the agent's chat already ends with is not shown twice", () => {
  const asked = {
    ...ANSWERED,
    messages: [
      ...ANSWERED.messages,
      { id: "m3", role: "you" as const, text: "Is it tested?", anchor: null },
    ],
    isWorking: true,
  };
  const chat = withQueued(asked, [question("a", "Is it tested?")], 2_000);
  assert.equal(chat.messages.length, 3);
  assert.equal(chat.isWorking, true);
});

test("a question about a line names it, and a chat with nothing yet starts empty", () => {
  const ask = question("a", "Why?");
  ask.input.anchor = { path: "src/retry.ts", line: 12, side: "RIGHT" };
  const chat = withQueued(null, [ask], 2_000);
  assert.deepEqual(chat.messages, [
    { id: "queued:a", role: "you", text: "Why?", anchor: "src/retry.ts:12", side: "RIGHT" },
  ]);
  assert.equal(chat.isWorking, true);
});

/** An intake whose storage answers `view` at once; `calls` says what the route did, in order. */
function intake(view: AskView, claim: "go" | "busy" | "done" = "go") {
  const calls: string[] = [];
  const answer: AskIntake = {
    claim: async (receipt) => {
      calls.push(`claim ${receipt}`);
      return claim;
    },
    finish: async (receipt, sent) => {
      calls.push(`finish ${receipt} ${sent}`);
    },
    limited: async () => {
      calls.push("limited");
      return null;
    },
    queue: async (stored) => {
      calls.push(stored ? `queue ${stored.id}` : "read");
      return view;
    },
    busy: () => new Response(null, { status: 503 }),
  };
  return { answer, calls };
}

const STORED: AskView = { chat: ANSWERED, queued: [question("ref-1", "Is it tested?")] };

test("a question is answered 202 once it is stored, with the chat so far and the question at its end, working", async () => {
  const { answer, calls } = intake(STORED);
  const response = await acceptAsk(
    answer,
    question("ref-1", "Is it tested?"),
    "ask:acme/api#7:ref-1",
  );
  assert.equal(response.status, 202);
  const chat = (await response.json()) as AskChat;
  assert.deepEqual(
    chat.messages.map((message) => message.text),
    ["What does it change?", "The retry.", "Is it tested?"],
  );
  assert.equal(chat.isWorking, true);
  assert.equal(chat.problem, null);
  assert.deepEqual(calls, [
    "claim ask:acme/api#7:ref-1",
    "limited",
    "queue ref-1",
    "finish ask:acme/api#7:ref-1 true",
  ]);
});

test("a repeat of the same question is the one already stored: nothing is queued twice", async () => {
  const { answer, calls } = intake(STORED, "done");
  const response = await acceptAsk(
    answer,
    question("ref-1", "Is it tested?"),
    "ask:acme/api#7:ref-1",
  );
  assert.equal(response.status, 202);
  assert.deepEqual(calls, ["claim ask:acme/api#7:ref-1", "read"]);
  const chat = (await response.json()) as AskChat;
  assert.equal(chat.messages.filter((message) => message.text === "Is it tested?").length, 1);
});

test("a copy already being stored is busy, and a refused one leaves no receipt", async () => {
  const empty: AskView = { chat: null, queued: [] };
  assert.equal(
    (await acceptAsk(intake(empty, "busy").answer, question("r", "q"), "ask:x:r")).status,
    503,
  );
  const refused = intake(empty);
  refused.answer.limited = async () => new Response(null, { status: 429 });
  assert.equal((await acceptAsk(refused.answer, question("r", "q"), "ask:x:r")).status, 429);
  assert.deepEqual(refused.calls, ["claim ask:x:r", "finish ask:x:r false"], "nothing queued");
});
