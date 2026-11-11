// Ask on a subscription: a question becomes one container turn, and the chat and transcript live in R2 between turns.
import assert from "node:assert/strict";
import test from "node:test";
import type { AskInput } from "../src/ask-chat.ts";
import { askOnSubscription, subscriptionChat, type SubscriptionRecord, TURN_LOST_MS } from "../src/ask-subscription.ts";
import type { Env } from "../src/env.ts";
import type { RepoFullName, Sha } from "../src/ids.ts";

function memoryR2() {
  const objects = new Map<string, string>();
  return {
    objects,
    get: async (key: string) => (objects.has(key)
      ? { json: async () => JSON.parse(objects.get(key)!), text: async () => objects.get(key)! } : null),
    put: async (key: string, value: string) => void objects.set(key, value),
  };
}

const HEAD = "a".repeat(40) as Sha;
const REPO = "acme/api" as RepoFullName;
const input = (question: string): AskInput => ({ question, head: HEAD, anchor: null });

function world(answers: Record<string, unknown>[]) {
  const sent: Record<string, unknown>[] = [];
  const agent = {
    idFromName: (name: string) => name,
    get: () => ({
      fetch: async (url: string, init: RequestInit) => {
        assert.equal(url, "http://agent/ask");
        sent.push(JSON.parse(String(init.body)) as Record<string, unknown>);
        return Response.json(answers.shift());
      },
    }),
  };
  const r2 = memoryR2();
  const env = { DIFFS: r2, AGENT: agent, CLAUDE_CODE_OAUTH_TOKEN: "oat" } as unknown as Env;
  const services = { system: "sys", token: async () => "read-token", diff: async () => "diff --git a/x b/x", budgetUsd: 5,
    now: () => 1_000 };
  const record = () => JSON.parse(r2.objects.get(`ask/${REPO}/7.json`)!) as SubscriptionRecord;
  return { sent, r2, env, services, record };
}

test("a question's answer joins the chat, and the next question resumes the same session with its transcript", async () => {
  const w = world([
    { subtype: "success", text: "It retries twice.", session: "s1", entries: [{ type: "user" }, { type: "assistant" }],
      model: "claude-haiku-5-5", costUsd: 0.01 },
    { subtype: "success", text: "Yes.", session: "s1", entries: [{ type: "user" }], model: "claude-haiku-5-5", costUsd: 0.02 },
  ]);
  const choice = { model: "claude-haiku-5-5" as const, effort: "high" as const };
  await askOnSubscription(REPO, 7, input("How often does it retry?"), choice, w.env, w.services);
  assert.deepEqual(w.record().messages.map(({ role, text }) => [role, text]),
    [["you", "How often does it retry?"], ["agent", "It retries twice."]]);
  assert.equal(w.sent[0].session, null);
  assert.equal(w.sent[0].token, "read-token");
  assert.equal(w.sent[0].diff, "diff --git a/x b/x", "the PR's diff goes with the question");
  assert.equal(w.sent[0].scope, "self", "a self-hosted Worker's checkouts are its own");
  await askOnSubscription(REPO, 7, input("Is that enough?"), choice, w.env, w.services);
  assert.equal(w.sent[1].session, "s1");
  assert.deepEqual(w.sent[1].entries, [{ type: "user" }, { type: "assistant" }], "the stored transcript goes back");
  const chat = subscriptionChat(w.record(), 2_000);
  assert.equal(chat.messages.length, 4);
  assert.equal(chat.isWorking, false);
  assert.equal(chat.costCents, 3);
});

test("a failed turn ends working with a problem, and a turn running too long reads as lost", async () => {
  const w = world([{ error: "boom" }, { error: "boom" }, { error: "boom" }]);
  await askOnSubscription(REPO, 7, input("Why?"), { model: "claude-haiku-5-5", effort: "high" }, w.env,
    w.services).catch(() => {});
  const chat = subscriptionChat(w.record(), 2_000);
  assert.equal(chat.isWorking, false);
  assert.match(chat.problem ?? "", /couldn't be reached/);
  const running = { ...w.record(), workingSince: 0, problem: null };
  assert.equal(subscriptionChat(running, TURN_LOST_MS - 1).isWorking, true);
  assert.match(subscriptionChat(running, TURN_LOST_MS).problem ?? "", /stopped/);
});
