import assert from "node:assert/strict";
import { test } from "vitest";
import { answerText, askContainer } from "../../src/agent-container.ts";
import type { Env } from "../../src/env.ts";

/** The container's answer in lines, in chunks that need not end where a line does. */
function inLines(...chunks: string[]): Response {
  const bytes = new TextEncoder();
  return new Response(
    new ReadableStream({
      start(controller) {
        for (const chunk of chunks) {
          controller.enqueue(bytes.encode(chunk));
        }
        controller.close();
      },
    }),
    { headers: { "content-type": "application/x-ndjson" } },
  );
}

function agent(...answers: Response[]) {
  const sent: Record<string, unknown>[] = [];
  const binding = {
    idFromName: (name: string) => name,
    get: () => ({
      fetch: async (_url: string, init: RequestInit) => {
        sent.push(JSON.parse(String(init.body)) as Record<string, unknown>);
        return answers.shift()!;
      },
    }),
  };
  return { sent, env: { CLAUDE_CODE_OAUTH_TOKEN: "a", AGENT: binding } as unknown as Env };
}

test("each line before the answer's is told as it comes", async () => {
  const told: string[] = [];
  const text = await answerText(
    inLines(
      '{"activity":"Reading the diff"}\n{"activ',
      'ity":"Reading retry.ts"}\n{"text":"',
      'Yes."}',
    ),
    (activity) => told.push(activity),
  );
  assert.deepEqual(told, ["Reading the diff", "Reading retry.ts"]);
  assert.equal(text, '{"text":"Yes."}');
});

test("a container from before progress answers the JSON alone", async () => {
  assert.equal(await answerText(Response.json({ text: "Yes." }), () => {}), '{"text":"Yes."}');
});

test("only a run someone follows asks for progress", async () => {
  const followed = agent(inLines('{"text":"Yes."}'));
  const quiet = agent(Response.json({ output: 1 }));
  await askContainer(
    "/ask",
    {},
    followed.env,
    async () => {},
    "ask:self",
    () => {},
  );
  await askContainer("/run", {}, quiet.env, async () => {});
  assert.equal(followed.sent[0]?.progress, true);
  assert.equal("progress" in quiet.sent[0]!, false);
});

test("an answer cut short after its progress goes again", async () => {
  const cut = agent(inLines('{"activity":"Reading the diff"}\n'), inLines('{"text":"Yes."}'));
  const answer = await askContainer<{ error?: string; text?: string }>(
    "/ask",
    {},
    cut.env,
    async () => {},
    "ask:self",
    () => {},
  );
  assert.equal(answer.text, "Yes.");
});
