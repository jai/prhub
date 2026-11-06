import assert from "node:assert/strict";
import { test } from "node:test";
import { askPrompt, chatOf, parseAskInput } from "../src/ask-chat.ts";

const head = "504754b2bc3ce5db892dde980e4bc83b60ff7a68";
const moved = "1111111111111111111111111111111111111111";
const anchor = { path: "a/b.tf", line: 12, side: "RIGHT" as const, code: "x = 1" };
const said = (id: string, type: string, text: string) => ({ id, type, content: [{ type: "text", text }] });

test("a question needs words and a commit", () => {
  assert.equal(parseAskInput({ question: "  ", head }), null);
  assert.equal(parseAskInput({ question: "why?", head: "main" }), null);
  assert.equal(parseAskInput({ question: "x".repeat(4_001), head }), null);
  assert.equal(parseAskInput(null), null);
  assert.deepEqual(parseAskInput({ question: " why? ", head }), { question: "why?", head, anchor: null });
  assert.equal(parseAskInput({ question: "why?", head, anchor: { path: "a", line: "1", side: "RIGHT" } })?.anchor, null);
  assert.deepEqual(parseAskInput({ question: "why?", head, anchor })?.anchor, anchor);
});

test("the agent is told to move only when the PR has", () => {
  assert.doesNotMatch(askPrompt({ question: "why?", head, anchor: null }, head), /git fetch/);
  assert.match(askPrompt({ question: "why?", head, anchor: null }, moved), new RegExp(`git fetch origin ${head}`));
});

test("the phone sees Jai's words and the line, not the context around them", () => {
  const text = askPrompt({ question: "Why this?", head, anchor }, null);
  const chat = chatOf([said("1", "user.message", text)], 3);
  assert.deepEqual(chat.messages, [{ id: "1", role: "you", text: "Why this?", anchor: "a/b.tf:12" }]);
  assert.equal(chat.costCents, 3);
});

test("it works from the question until the session goes idle, saying what it reads", () => {
  const asked = said("1", "user.message", askPrompt({ question: "q", head, anchor: null }, null));
  // Idle from before the question is still in the history, ahead of it.
  const idle = { id: "0", type: "session.status_idle", stop_reason: { type: "end_turn" } };
  assert.equal(chatOf([idle, asked], null).isWorking, true);
  const reading = { id: "2", type: "agent.tool_use", name: "read", input: { file_path: "/workspace/r/main.tf" } };
  assert.equal(chatOf([asked, reading], null).activity, "Reading main.tf");
  const shell = { id: "2", type: "agent.tool_use", name: "bash", input: {} };
  assert.equal(chatOf([asked, shell], null).activity, "Reading the repo");
  const done = chatOf([asked, reading, said("3", "agent.message", "a"), { ...idle, id: "4" }], null);
  assert.equal(done.isWorking, false);
  assert.equal(done.activity, null);
  assert.deepEqual(done.messages.map((message) => message.role), ["you", "agent"]);
});

test("it says why it stopped, and a new question clears that", () => {
  const asked = said("1", "user.message", "q");
  const capped = { id: "2", type: "session.status_idle", stop_reason: { type: "budget_reached" } };
  assert.equal(chatOf([asked, capped], null).problem, "This chat reached its spending limit.");
  assert.equal(chatOf([asked, capped, said("3", "user.message", "again")], null).problem, null);
  const ended = chatOf([asked, { id: "2", type: "session.status_terminated" }], null);
  assert.equal(ended.isWorking, false);
  assert.match(ended.problem ?? "", /ended/);
  assert.equal(chatOf([], null).messages.length, 0);
});

test("waiting on a tool's permission is still working", () => {
  const asked = said("1", "user.message", "q");
  const waiting = { id: "2", type: "session.status_idle", stop_reason: { type: "requires_action" } };
  assert.equal(chatOf([asked, waiting], null).isWorking, true);
});
