// What the tools say back, and the tools that only hand something to the Worker: in process, fetch stubbed.
import assert from "node:assert/strict";
import { test, vi } from "vitest";
import { readOnlyHooks, readToolNames } from "../../gate.mjs";
import {
  actHandler,
  cut,
  draftReviewHandler,
  githubApiHandler,
  KEPT,
  LINEAR_ACTS,
  linearActHandler,
  redact,
  said,
} from "../../replies.mjs";

const hook = readOnlyHooks("/w/acme/api/7", "/w/.clones", null, (path) => path)[0].hooks[0];

test("a repo the token can't reach answers that the reviewer can't access it", async () => {
  vi.stubGlobal(
    "fetch",
    async (url) =>
      new Response('{"message":"Not Found"}', {
        status: String(url).includes("/secret") ? 404 : 200,
      }),
  );
  const call = githubApiHandler({ token: "fake-install-token", prRepo: "acme/api" });
  const denied = await call({ path: "/repos/acme/secret/releases/latest" });
  assert.equal(denied.isError, true);
  assert.match(
    denied.content[0].text,
    /can't access acme\/secret: the reviewer can't see it, or the GitHub App isn't installed/,
  );
  const fine = await call({ path: "/repos/acme/actions/releases/latest" });
  assert.equal(fine.isError, false);
});

test("tool output never carries the subscription token either", () => {
  vi.stubEnv("CLAUDE_CODE_OAUTH_TOKEN", "sk-subscription-value");
  const text = said("+sk-subscription-value\n+ghs-install\n", "ghs-install");
  assert.doesNotMatch(text, /sk-subscription-value|ghs-install/);
  assert.equal(text, "+[redacted]\n+[redacted]\n");
});

test("redaction replaces every copy of each secret and skips empty ones", () => {
  assert.equal(redact("a-x-a", ["a", null, ""]), "[redacted]-x-[redacted]");
  assert.equal(redact(42, [undefined]), "42");
});

test("one tool answer is cut at KEPT characters, and says so", () => {
  assert.equal(cut("short"), "short");
  const exact = "x".repeat(KEPT);
  assert.equal(cut(exact), exact);
  const long = cut("x".repeat(KEPT + 5));
  assert.equal(long, `${exact}\n[cut at ${KEPT} characters]`);
});

test("draft_review keeps the draft for the Worker, posts nothing, and the hook lets it through", async () => {
  let kept = null;
  const draft = {
    event: "REQUEST_CHANGES",
    body: "Retry loses the error.",
    comments: [{ path: "src/a.ts", line: 12, side: "RIGHT", body: "Keep the cause." }],
  };
  const answer = await draftReviewHandler((made) => {
    kept = made;
  })(draft);
  assert.deepEqual(kept, draft);
  assert.match(answer.content[0].text, /with 1 line comment\. Nothing is posted/);
  assert.deepEqual(await hook({ tool_name: "mcp__prhub__draft_review", tool_input: draft }), {});
  assert.ok(readToolNames(false).includes("mcp__prhub__draft_review"));
});

test("github_act hands the action to the Worker and acts on nothing itself", async () => {
  const acts = [];
  const action = {
    kind: "review",
    event: "APPROVE",
    body: "",
    commit: "a".repeat(40),
    comments: [],
  };
  const answer = await actHandler((one) => acts.push(one))({ action });
  assert.deepEqual(acts, [action]);
  assert.match(answer.content[0].text, /Queued/);
  assert.deepEqual(await hook({ tool_name: "mcp__prhub__github_act", tool_input: { action } }), {});
});

test("linear_act proposes a comment for the reviewer to post, holds no Linear key, and posts nothing", async () => {
  const proposed = [];
  const answer = await linearActHandler((comment) => proposed.push(comment))({
    issue: "eng-12",
    body: "@Octbot rename the flag",
  });
  assert.deepEqual(proposed, [{ issue: "ENG-12", body: "@Octbot rename the flag" }]);
  assert.match(answer.content[0].text, /Nothing is posted/);
  assert.deepEqual(
    await hook({ tool_name: "mcp__prhub__linear_act", tool_input: { issue: "ENG-12", body: "x" } }),
    {},
  );
  assert.ok(readToolNames(false).includes("mcp__prhub__linear_act"));
  assert.equal(LINEAR_ACTS, 3);
});
