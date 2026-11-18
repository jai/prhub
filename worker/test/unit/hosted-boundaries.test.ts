import assert from "node:assert/strict";
import { test } from "node:test";
import { aiStoreKey } from "../../src/ai-run.ts";
import { askRecordKey } from "../../src/ask-chat.ts";
import { aiJobs, type Env, prIndex, scopedKey } from "../../src/env.ts";
import { userEnv } from "../../src/hosted.ts";
import { parseRepoFullName, parseSha, type RepoFullName } from "../../src/ids.ts";
import { parseAppDelivery } from "../../src/installations.ts";
import { gitHubReserveOf, parseLimits, WorkerMode } from "../../src/limits.ts";
import { backoffOf, newRateLimitState, observe, stops } from "../../src/rate-limit.ts";

const SHA = "a".repeat(40);
const RESERVE = gitHubReserveOf(parseLimits({}, WorkerMode.Hosted));
const repo = (name: string) => parseRepoFullName(name) as RepoFullName;
const limitHeaders = (
  remaining: number,
  reset = 2_000_000_000,
  extra: Record<string, string> = {},
) => ({
  "x-ratelimit-remaining": String(remaining),
  "x-ratelimit-limit": "5000",
  "x-ratelimit-reset": String(reset),
  ...extra,
});

test("each person's rows, details, diffs, AI answers, Ask chats and devices live under their own names", () => {
  const named: string[] = [];
  const namespace = {
    idFromName: (name: string) => named.push(name) && name,
    get: (id: string) => id,
  };
  const base = { DIFFS: {}, PR_INDEX: namespace, AI_JOBS: namespace } as unknown as Env;
  const a = userEnv(base, { userId: "1001", login: "alice", token: "ghu_a" });
  const b = userEnv(base, { userId: "2002", login: "bob", token: "ghu_b" });
  assert.notEqual(prIndex(a), prIndex(b));
  assert.notEqual(aiJobs(a), aiJobs(b));
  assert.deepEqual(named, ["user:1001", "user:2002", "user:1001", "user:2002"]);
  const pr = repo("acme/api");
  const job = {
    kind: "key_lines" as const,
    repo: pr,
    number: 7,
    head: parseSha(SHA) ?? (SHA as never),
    context: 3,
  };
  for (const [keyA, keyB] of [
    [scopedKey(a, "acme/api/7/x.diff"), scopedKey(b, "acme/api/7/x.diff")],
    [askRecordKey(pr, 7, a), askRecordKey(pr, 7, b)],
    [aiStoreKey(job, a), aiStoreKey(job, b)],
  ]) {
    assert.ok(keyA.startsWith("users/1001/") && keyB.startsWith("users/2002/"), `${keyA} ${keyB}`);
  }
  assert.equal(
    askRecordKey(pr, 7, base),
    "ask/acme/api/7.json",
    "a self-hosted Worker's keys are as they were",
  );
  assert.equal(aiStoreKey(job, base).startsWith("ai/acme/api/7/"), true);
});

test("GitHub's rate-limit headers become a backoff: low, none left, or retry-after", () => {
  const now = 1_900_000_000_000;
  const answer = (status: number, headers: Record<string, string>) =>
    new Response(null, { status, headers });
  assert.equal(backoffOf(answer(200, limitHeaders(4_000)), now, RESERVE), null);
  assert.deepEqual(backoffOf(answer(200, limitHeaders(400, 1_900_000_900)), now, RESERVE), {
    kind: "low",
    until: 1_900_000_900_000,
  });
  assert.deepEqual(
    backoffOf(answer(200, limitHeaders(400)), now, RESERVE),
    { kind: "low", until: now + 3_600_000 },
    "never past GitHub's hour",
  );
  assert.deepEqual(backoffOf(answer(200, limitHeaders(99, 1_900_000_100)), now, RESERVE), {
    kind: "low",
    until: 1_900_000_100_000,
  });
  assert.deepEqual(backoffOf(answer(403, limitHeaders(0, 1_900_000_100)), now, RESERVE), {
    kind: "primary",
    until: 1_900_000_100_000,
  });
  assert.deepEqual(
    backoffOf(
      answer(403, limitHeaders(3_000, 1_900_000_100, { "retry-after": "30" })),
      now,
      RESERVE,
    ),
    { kind: "secondary", until: now + 30_000 },
  );
  assert.deepEqual(backoffOf(answer(429, {}), now, RESERVE), {
    kind: "secondary",
    until: now + 60_000,
  });
  assert.equal(
    backoffOf(answer(403, {}), now, RESERVE),
    null,
    "a plain 403 is a permission, not a limit",
  );
  assert.equal(backoffOf(answer(404, limitHeaders(4_999)), now, RESERVE), null);
});

test("a run keeps its calls and the strictest backoff; low stops only background reads", () => {
  const now = 1_900_000_000_000;
  const state = newRateLimitState();
  observe(state, new Response(null, { headers: limitHeaders(4_000) }), now, RESERVE);
  observe(state, new Response(null, { headers: limitHeaders(300, 1_900_000_500) }), now, RESERVE);
  assert.equal(state.calls, 2);
  assert.equal(state.remaining, 300);
  assert.deepEqual(state.backoff, { kind: "low", until: 1_900_000_500_000 });
  assert.equal(stops(state.backoff, now, true), true);
  assert.equal(stops(state.backoff, now, false), false, "the person's own request still goes");
  assert.equal(stops({ kind: "secondary", until: now + 1 }, now, false), true);
  assert.equal(stops({ kind: "primary", until: now }, now, true), false, "a backoff ends");
});

test("each routed event parses to what it marks, and the rest are ignored", () => {
  const base = { installation: { id: 5 }, repository: { full_name: "o/r" } };
  assert.deepEqual(
    parseAppDelivery("pull_request", {
      ...base,
      pull_request: {
        number: 3,
        user: { login: "a" },
        requested_reviewers: [{ login: "b" }, { name: "team" }],
      },
    }),
    {
      kind: "target",
      installationId: "5",
      target: { kind: "pr", repo: "o/r", number: 3, author: "a", reviewers: ["b"] },
    },
  );
  assert.deepEqual(
    parseAppDelivery("issue_comment", {
      ...base,
      issue: { number: 4, pull_request: {}, user: null },
    }),
    {
      kind: "target",
      installationId: "5",
      target: { kind: "pr", repo: "o/r", number: 4, author: null, reviewers: [] },
    },
  );
  assert.equal(
    parseAppDelivery("issue_comment", { ...base, issue: { number: 4, user: null } }),
    null,
    "an issue's",
  );
  assert.deepEqual(parseAppDelivery("status", { ...base, sha: SHA }), {
    kind: "target",
    installationId: "5",
    target: { kind: "head", repo: "o/r", sha: SHA },
  });
  assert.equal(parseAppDelivery("status", { ...base, sha: "nope" }), null);
  assert.equal(parseAppDelivery("check_run", { ...base, check_run: {} }), null);
  assert.equal(
    parseAppDelivery("pull_request", {
      repository: { full_name: "o/r" },
      pull_request: { number: 1 },
    }),
    null,
    "no installation",
  );
  assert.deepEqual(
    parseAppDelivery("installation", {
      action: "created",
      installation: { id: 5, account: { login: "acme" } },
      sender: { id: 7 },
      repositories: [{ full_name: "acme/x" }, { full_name: "not a repo" }],
    }),
    {
      kind: "installation",
      installationId: "5",
      action: "created",
      account: "acme",
      repos: ["acme/x"],
      senderId: 7,
    },
  );
});
