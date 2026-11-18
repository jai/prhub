import assert from "node:assert/strict";
import { test } from "node:test";
import { ASK_HANDOVER_MS, NOT_HANDED_OVER, withQueued } from "../../src/ask-queue.ts";
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
