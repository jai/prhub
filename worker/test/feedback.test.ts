import assert from "node:assert/strict";
import { test } from "node:test";
import { chatOf } from "../src/ask-chat.ts";
import { feedbackPrompt, isFeedbackId, parseFeedbackInput, titleOf } from "../src/feedback.ts";

test("feedback is words with the build it is about, and nothing else gets through", () => {
  assert.deepEqual(parseFeedbackInput({ text: "  The back button jumps  ", build: "142" }),
    { text: "The back button jumps", build: "142" });
  assert.equal(parseFeedbackInput({ text: "   " }), null);
  assert.equal(parseFeedbackInput({ text: "x".repeat(8_001) }), null);
  assert.equal(parseFeedbackInput({ text: "ok", build: "1; rm -rf /" })?.build, null);
  assert.equal(isFeedbackId("sesn_011CgjX"), true);
  assert.equal(isFeedbackId("../threads.json"), false);
});

test("the chat shows Jai's words without what the agent was told around them", () => {
  const sent = feedbackPrompt({ text: "Make the dot bigger", build: "142" });
  const chat = chatOf([{ id: "e1", type: "user.message", content: [{ type: "text", text: sent }] }], null, "Feedback: ");
  assert.equal(chat.messages[0].text, "Make the dot bigger");
  assert.equal(chat.isWorking, true);
  assert.equal(titleOf(`${"a".repeat(80)}\nsecond line`).length, 60);
});
