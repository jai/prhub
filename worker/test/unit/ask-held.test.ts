import assert from "node:assert/strict";
import { test } from "vitest";
import type { AskChat } from "../../src/ask-chat.ts";
import { ASK_HELD_MS, ASK_VERSION, askWaitMs, type HeldAsk, heldAsk } from "../../src/ask-held.ts";
import { ANSWERED } from "../support/ask-queue-values.ts";

const WORKING: AskChat = { ...ANSWERED, isWorking: true, activity: "Reading the repo" };

/** A chat whose waits each run the next of `during`, which changes it or lets the time pass. */
function world(
  chat: AskChat,
  during: ((now: { chat: AskChat; activity: string | null; clock: number }) => void)[],
) {
  const now = { chat, activity: null as string | null, clock: 0 };
  const waits: number[] = [];
  const held: HeldAsk = {
    now: async () => ({ version: waits.length, activity: now.activity }),
    chat: async () => now.chat,
    wait: async (_seen, ms) => {
      waits.push(ms);
      const step = during.shift();
      if (step) {
        step(now);
      } else {
        now.clock += ms;
      }
    },
    clock: () => now.clock,
  };
  return { held, waits };
}

const at = (query = "") => new URL(`https://worker.test/prs/acme/api/7/ask${query}`);

async function versionOf(chat: AskChat) {
  return (await heldAsk(at(), world(chat, []).held)).headers.get(ASK_VERSION)!;
}

test("a read with no version answers at once, with the version the next one waits from", async () => {
  const { held, waits } = world(WORKING, []);
  const answer = await heldAsk(at("?wait=10"), held);
  assert.equal(answer.status, 200);
  assert.deepEqual(await answer.json(), WORKING);
  assert.match(answer.headers.get(ASK_VERSION)!, /^[0-9a-f]{24}$/);
  assert.deepEqual(waits, []);
});

test("the answer comes as soon as the chat changes", async () => {
  const version = await versionOf(WORKING);
  const { held, waits } = world(WORKING, [
    (now) => {
      now.clock = 3_000;
      now.chat = ANSWERED;
    },
  ]);
  const answer = await heldAsk(at(`?wait=10&version=${version}`), held);
  assert.equal(answer.status, 200);
  assert.deepEqual(await answer.json(), ANSWERED);
  assert.equal(waits.length, 1);
});

test("what the agent is doing is a change, and shows in the chat", async () => {
  const version = await versionOf(WORKING);
  const { held } = world(WORKING, [(now) => (now.activity = "Reading retry.ts")]);
  const answer = await heldAsk(at(`?wait=10&version=${version}`), held);
  assert.equal(((await answer.json()) as AskChat).activity, "Reading retry.ts");
});

test("a wake that changed nothing waits out the rest, then says there is nothing new", async () => {
  const version = await versionOf(WORKING);
  const { held, waits } = world(WORKING, [(now) => (now.clock = 4_000)]);
  const answer = await heldAsk(at(`?wait=10&version=${version}`), held);
  assert.equal(answer.status, 204);
  assert.equal(answer.headers.get(ASK_VERSION), version);
  assert.deepEqual(waits, [10_000, 6_000]);
});

test("a chat at rest is not held, nor is a read that asks for no wait", async () => {
  const rest = world(ANSWERED, []);
  const answered = await versionOf(ANSWERED);
  assert.equal((await heldAsk(at(`?wait=10&version=${answered}`), rest.held)).status, 204);
  const working = world(WORKING, []);
  const version = await versionOf(WORKING);
  assert.equal((await heldAsk(at(`?version=${version}`), working.held)).status, 204);
  assert.deepEqual([...rest.waits, ...working.waits], []);
});

test("the wait is the phone's seconds, at most the Worker's, and 0 for anything else", () => {
  assert.equal(askWaitMs(at("?wait=3")), 3_000);
  assert.equal(askWaitMs(at("?wait=600")), ASK_HELD_MS);
  for (const query of ["", "?wait=", "?wait=-4", "?wait=soon"]) {
    assert.equal(askWaitMs(at(query)), 0, query);
  }
});
