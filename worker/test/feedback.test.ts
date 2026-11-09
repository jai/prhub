import assert from "node:assert/strict";
import { test } from "node:test";
import { chatOf } from "../src/ask-chat.ts";
import {
  feedbackContent, feedbackPrompt, isFeedbackId, parseFeedbackInput, titleOf, withImageCounts,
} from "../src/feedback.ts";

test("feedback is words with the build it is about, and nothing else gets through", () => {
  assert.deepEqual(parseFeedbackInput({ text: "  The back button jumps  ", build: "142" }),
    { text: "The back button jumps", build: "142", images: [] });
  assert.equal(parseFeedbackInput({ text: "   " }), null);
  assert.equal(parseFeedbackInput({ text: "x".repeat(8_001) }), null);
  assert.equal(parseFeedbackInput({ text: "ok", build: "1; rm -rf /" })?.build, null);
  assert.equal(isFeedbackId("sesn_011CgjX"), true);
  assert.equal(isFeedbackId("../threads.json"), false);
});

test("the chat shows Jai's words without what the agent was told around them", () => {
  const sent = feedbackPrompt({ text: "Make the dot bigger", build: "142", images: [] });
  const chat = chatOf([{ id: "e1", type: "user.message", content: [{ type: "text", text: sent }] }], null, "Feedback: ");
  assert.equal(chat.messages[0].text, "Make the dot bigger");
  assert.equal(chat.isWorking, true);
  assert.equal(titleOf(`${"a".repeat(80)}\nsecond line`).length, 60);
});

const PNG = "iVBORw0KGgoAAAANSUhEUg==";
const JPEG = "/9j/4AAQSkZJRg==";

test("a screenshot goes to the agent as an image block after the words, and may stand alone", () => {
  const input = parseFeedbackInput({ text: "", build: "150", images: [{ media_type: "image/png", data: PNG }] });
  assert.ok(input);
  const content = feedbackContent(input);
  assert.equal(content.length, 2);
  assert.match((content[0] as { text: string }).text, /attached a screenshot/);
  assert.deepEqual(content[1], { type: "image", source: { type: "base64", media_type: "image/png", data: PNG } });
  assert.equal(titleOf(input.text), "Screenshot");
});

test("only up to four JPEG or PNG screenshots of at most 1.5 MB get through", () => {
  const one = { media_type: "image/jpeg", data: JPEG };
  assert.equal(parseFeedbackInput({ text: "x", images: [one, one, one, one] })?.images.length, 4);
  for (const images of [
    [one, one, one, one, one],
    [{ media_type: "image/gif", data: JPEG }],
    [{ media_type: "image/png", data: JPEG }],
    [{ media_type: "image/jpeg", data: "/9j/ not base64" }],
    [{ media_type: "image/jpeg", data: `/9j/${"A".repeat(2_000_000)}` }],
    "nope",
  ]) {
    assert.equal(parseFeedbackInput({ text: "x", images }), null);
  }
  assert.equal(parseFeedbackInput({ text: " ", images: [] }), null);
});

test("the chat says how many screenshots each message carried, and hides the placeholder words", () => {
  const input = parseFeedbackInput({ text: "", images: [{ media_type: "image/png", data: PNG }] })!;
  const events = [{ id: "e1", type: "user.message", content: feedbackContent(input) }];
  const chat = chatOf(events as Parameters<typeof chatOf>[0], null, "Feedback: ");
  assert.deepEqual(withImageCounts(chat.messages, events).map(({ text, images }) => ({ text, images })),
    [{ text: "", images: 1 }]);
});
