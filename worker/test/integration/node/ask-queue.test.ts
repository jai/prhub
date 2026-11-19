import assert from "node:assert/strict";
import { afterEach, test } from "vitest";
import type { AskChat } from "../../../src/ask-chat.ts";
import {
  acceptAsk,
  askView,
  type AskIntake,
  createAskTables,
  drainAsks,
  queueAsk,
  rememberChat,
} from "../../../src/ask-queue.ts";
import { ANSWERED, PR, question } from "../../support/ask-queue-values.ts";
import { closeMemorySql, memorySql } from "../../support/memory-sql.ts";

afterEach(closeMemorySql);

function queue() {
  const sql = memorySql();
  createAskTables(sql);
  return sql;
}

/** An intake whose storage answers at once; `calls` says what the route did, in order. */
function intake(sql = queue(), claim: "go" | "busy" | "done" = "go") {
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

test("a stored question answers before its unfinished handover completes", async () => {
  const { answer, sql } = intake();
  const response = await acceptAsk(answer, question("ref-1", "Is it tested?"), null);
  assert.equal(response.status, 202);
  let release!: (answer: string | null) => void;
  const handover = new Promise<string | null>((resolve) => {
    release = resolve;
  });
  let handedOver = false;
  const slow = drainAsks(sql, async () => {
    const answer = await handover;
    handedOver = true;
    return answer;
  });
  assert.equal(handedOver, false, "the stored response needs no completed handover");
  assert.equal(askView(sql, PR).queued.length, 1, "pending until the handover completes");
  release(null);
  await slow;
  assert.equal(handedOver, true);
  assert.deepEqual(askView(sql, PR).queued, []);
});

test("a repeat of the same question is the one already stored: nothing is queued twice", async () => {
  const { answer, calls, sql } = intake(queue(), "done");
  queueAsk(sql, question("ref-1", "Is it tested?"));
  const response = await acceptAsk(
    answer,
    question("ref-1", "Is it tested?"),
    "ask:acme/api#7:ref-1",
  );
  assert.equal(response.status, 202);
  assert.deepEqual(calls, ["claim ask:acme/api#7:ref-1", "read"]);
  assert.equal(askView(sql, PR).queued.length, 1);
});

test("a copy already being stored is busy, and a refused one leaves no receipt", async () => {
  assert.equal(
    (await acceptAsk(intake(queue(), "busy").answer, question("r", "q"), "ask:x:r")).status,
    503,
  );
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
  assert.deepEqual(
    askView(sql, PR).queued.map((ask) => ask.id),
    ["c"],
    "Try again replaces the failed question",
  );
});
