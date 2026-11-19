import assert from "node:assert/strict";
import { afterEach, test } from "vitest";
import { summaryOf } from "../../src/ai.ts";
import { repoOf, type Sha } from "../../src/ids.ts";
import { runAiJob } from "../../src/ai-run.ts";
import type { Env } from "../../src/env.ts";
import type { AiJob } from "../../src/models.ts";

const SUMMARY = {
  risk: "low" as const,
  riskWhy: "Small.",
  points: ["One"],
  bugs: [],
  slop: { isSlop: false, tells: [] },
};

test("one ticket: fits is a tick with no gaps, a mismatch keeps up to four gaps", () => {
  const one = { keys: ["CORE-12"], text: "CORE-12: Sync holidays" };
  assert.deepEqual(
    summaryOf({ ...SUMMARY, requirements: { fits: true, gaps: ["ignored"] } }, [], one)
      .requirements,
    { state: "fits", tickets: ["CORE-12"], gaps: [] },
  );
  const gaps = [" No dry run ", "", "B", "C", "D", "E"];
  assert.deepEqual(
    summaryOf({ ...SUMMARY, requirements: { fits: false, gaps } }, [], one).requirements,
    { state: "mismatch", tickets: ["CORE-12"], gaps: ["No dry run", "B", "C", "D"] },
  );
});

test("more than one ticket says so and is not checked; none, or no answer, says nothing", () => {
  const two = { keys: ["CORE-12", "ENG-3"], text: null };
  assert.deepEqual(summaryOf(SUMMARY, [], two).requirements, {
    state: "multiple",
    tickets: ["CORE-12", "ENG-3"],
    gaps: [],
  });
  assert.equal(summaryOf(SUMMARY, [], { keys: [], text: null }).requirements, undefined);
  assert.equal(summaryOf(SUMMARY, [], { keys: ["CORE-12"], text: "t" }).requirements, undefined);
});

test("AI slop keeps up to four tells; a description that isn't slop has none", () => {
  const none = { keys: [], text: null };
  const tells = [" Hype: 'seamless' ", "", "B", "C", "D", "E"];
  assert.deepEqual(summaryOf({ ...SUMMARY, slop: { isSlop: true, tells } }, [], none).slop, {
    isSlop: true,
    tells: ["Hype: 'seamless'", "B", "C", "D"],
  });
  assert.deepEqual(summaryOf({ ...SUMMARY, slop: { isSlop: false, tells } }, [], none).slop, {
    isSlop: false,
    tells: [],
  });
});

const HEAD = "c".repeat(40) as Sha;
const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

/** GitHub with a PR on `branch`, and Linear holding `issues` by key. Linear's queries are recorded. */
function world(
  branch: string,
  issues: Record<string, { title: string; description: string }>,
  linear: string[],
): void {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url === "https://api.linear.app/graphql") {
      const { query } = JSON.parse(String(init?.body)) as { query: string };
      linear.push(query);
      const data = Object.fromEntries(
        [...query.matchAll(/(t\d+): issue\(id: "([^"]+)"\)/g)].map(([, alias, key]) => [
          alias,
          issues[key] ? { identifier: key, ...issues[key] } : null,
        ]),
      );
      return Response.json({ data });
    }
    if (url === "https://api.github.com/repos/acme/app/pulls/7") {
      const accept = new Headers(init?.headers).get("Accept") ?? "";
      return accept.includes("diff")
        ? new Response("diff --git a/x b/x\n")
        : Response.json({
            title: "Sync holidays",
            body: "",
            head: { sha: HEAD, ref: branch },
            base: { ref: "main" },
          });
    }
    return new Response("not here", { status: 500 });
  }) as typeof fetch;
}

/** The subscription's container, answering `requirements` when its schema asks for them. What it was sent is kept. */
function agent(sent: { system: string; prompt: string; schema: unknown }[]): Env["AGENT"] {
  return {
    idFromName: (name: string) => name,
    get: () => ({
      fetch: async (_url: string, init: RequestInit) => {
        const body = JSON.parse(String(init.body)) as {
          system: string;
          prompt: string;
          schema: unknown;
        };
        sent.push(body);
        const asksRequirements = JSON.stringify(body.schema).includes("requirements");
        const requirements = { fits: false, gaps: ["Skips Fridays"] };
        const summary = asksRequirements ? { ...SUMMARY, requirements } : SUMMARY;
        return Response.json({
          subtype: "success",
          output: { items: [], summary },
          model: "claude-sonnet-5-5",
          tokens: { input: 1, output: 1 },
          costUsd: 0,
        });
      },
    }),
  } as unknown as Env["AGENT"];
}

async function keyLinesFor(
  branch: string,
  issues: Record<string, { title: string; description: string }>,
) {
  const linear: string[] = [];
  const sent: { system: string; prompt: string; schema: unknown }[] = [];
  world(branch, issues, linear);
  const puts: string[] = [];
  const store = { put: async (_key: string, value: string) => puts.push(value) };
  const job: AiJob = {
    kind: "key_lines",
    repo: repoOf("acme/app"),
    number: 7,
    head: HEAD,
    context: 0,
  };
  const env = {
    GITHUB_TOKEN: "t",
    LINEAR_API_KEY: "lin",
    CLAUDE_CODE_OAUTH_TOKEN: "oat",
    AGENT: agent(sent),
  } as Env;
  await runAiJob(job, env, store as never);
  const stored = JSON.parse(puts[0]) as { summary: { requirements?: unknown }; error?: string };
  assert.equal(stored.error, undefined);
  return { requirements: stored.summary.requirements, sent, linear };
}

test("a PR whose branch names one ticket is checked against it, the ticket in the prompt", async () => {
  const { requirements, sent } = await keyLinesFor("alex/core-12-sync", {
    "CORE-12": { title: "Sync holidays", description: "Every weekday, Fridays too." },
  });
  assert.deepEqual(requirements, {
    state: "mismatch",
    tickets: ["CORE-12"],
    gaps: ["Skips Fridays"],
  });
  assert.match(
    sent[0].prompt,
    /<ticket>\nCORE-12: Sync holidays\n\nEvery weekday, Fridays too.\n<\/ticket>/,
  );
  assert.match(sent[0].system, /requirements/);
});

test("a branch key Linear lacks is no ticket; two it has are multiple, with no ticket in the prompt", async () => {
  const none = await keyLinesFor("fix-12", {});
  assert.equal(none.requirements, undefined);
  assert.doesNotMatch(none.sent[0].prompt, /<ticket>/);
  assert.doesNotMatch(JSON.stringify(none.sent[0].schema), /requirements/);

  const two = await keyLinesFor("core-12/eng-3", {
    "CORE-12": { title: "A", description: "" },
    "ENG-3": { title: "B", description: "" },
  });
  assert.deepEqual(two.requirements, {
    state: "multiple",
    tickets: ["CORE-12", "ENG-3"],
    gaps: [],
  });
  assert.doesNotMatch(two.sent[0].prompt, /<ticket>/);
});
