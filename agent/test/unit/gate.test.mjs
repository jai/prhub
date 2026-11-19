// The PreToolUse gate's decisions, with paths judged by a stand-in realpath: nothing on disk.
import assert from "node:assert/strict";
import { test } from "vitest";
import {
  cloneRefusal,
  gitRefusal,
  inGrant,
  isInside,
  readOnlyHooks,
  readToolNames,
} from "../../gate.mjs";

const asWritten = (path) => path;

async function decide(hooks, tool_name, tool_input) {
  const output = await hooks[0].hooks[0]({ tool_name, tool_input });
  return output.hookSpecificOutput?.permissionDecision ?? "allow";
}

test("the hook lets vetted reads and the web through, and denies writes, shells and other hosts", async () => {
  const hooks = readOnlyHooks("/w/acme/api/7", "/w/.clones", null, asWritten);
  assert.equal(
    await decide(hooks, "mcp__prhub__git", { args: ["log", "-5"], repo: "acme/actions" }),
    "allow",
  );
  assert.equal(
    await decide(hooks, "mcp__prhub__clone_repo", { repo: "acme/actions", ref: "v2" }),
    "allow",
  );
  assert.equal(
    await decide(hooks, "mcp__prhub__github_api", { path: "/repos/acme/api/pulls/7/comments" }),
    "allow",
  );
  assert.equal(
    await decide(hooks, "mcp__prhub__git", { args: ["push", "origin", "HEAD"] }),
    "deny",
  );
  assert.equal(
    await decide(hooks, "mcp__prhub__github_api", { path: "https://evil.example/" }),
    "deny",
  );
  assert.equal(await decide(hooks, "Bash", { command: "cat /proc/self/environ" }), "deny");
  assert.equal(await decide(hooks, "Write", { file_path: "/w/acme/api/7/a" }), "deny");
  assert.equal(await decide(hooks, "mcp__other__anything", {}), "deny");
  assert.equal(
    await decide(hooks, "WebSearch", { query: "grafana alert rule query_type" }),
    "allow",
  );
  assert.equal(
    await decide(hooks, "WebFetch", { url: "https://grafana.com/docs/", prompt: "summarise" }),
    "allow",
  );
});

test("hosted, a clone outside this question's grant can't be read, gitted or made", async () => {
  const cwd = "/w/acme/api/7";
  const clones = "/w/.clones";
  const hooks = readOnlyHooks(cwd, clones, ["acme/api", "Acme/Actions"], asWritten);
  assert.equal(
    await decide(hooks, "Read", { file_path: `${clones}/acme/actions/action.yml` }),
    "allow",
  );
  assert.equal(
    await decide(hooks, "Read", { file_path: `${clones}/acme/old/secret.yml` }),
    "deny",
    "access since lost",
  );
  assert.equal(
    await decide(hooks, "Grep", { pattern: "x", path: clones }),
    "deny",
    "not the clones as a whole",
  );
  assert.equal(await decide(hooks, "mcp__prhub__git", { args: ["log"], repo: "acme/old" }), "deny");
  assert.equal(await decide(hooks, "mcp__prhub__clone_repo", { repo: "acme/old" }), "deny");
  assert.equal(await decide(hooks, "mcp__prhub__clone_repo", { repo: "acme/actions" }), "allow");
  // The tools refuse with the same checks, before they touch anything.
  const reachable = ["acme/api"];
  assert.match(gitRefusal(["log"], "acme/old", reachable), /can't access acme\/old/);
  assert.match(cloneRefusal("acme/old", undefined, reachable), /can't access acme\/old/);
  assert.equal(gitRefusal(["log"], undefined, reachable), null, "the checkout needs no grant");
  assert.equal(cloneRefusal("acme/api", "main", reachable), null);
});

test("Glob patterns and Grep's file filter can't climb or start from / or ~", async () => {
  const cwd = "/w/acme/api/7";
  const hooks = readOnlyHooks(cwd, "/w/.clones", null, asWritten);
  assert.equal(await decide(hooks, "Glob", { pattern: "src/**/*.ts" }), "allow");
  assert.equal(await decide(hooks, "Glob", { pattern: "/etc/*" }), "deny");
  assert.equal(await decide(hooks, "Glob", { pattern: "../../*" }), "deny");
  assert.equal(await decide(hooks, "Glob", { pattern: "~/.ssh/*" }), "deny");
  assert.equal(await decide(hooks, "Grep", { pattern: "x", glob: "../*.env" }), "deny");
  assert.equal(await decide(hooks, "Grep", { pattern: "x" }), "allow", "no path is the checkout");
});

test("a path is judged where realpath says it points", () => {
  const followed = (path) => path.replace(/^\/w\/repo\/out(?=\/|$)/, "/etc");
  assert.equal(isInside("/w/repo", "/w/repo/src/a.ts", followed), true);
  assert.equal(isInside("/w/repo", "src/a.ts", followed), true, "relative is from the root");
  assert.equal(isInside("/w/repo", "/w/repo", followed), true);
  assert.equal(isInside("/w/repo", "/w/repo/out/passwd", followed), false, "a link out");
  assert.equal(isInside("/w/repo", "/w/repo-other/a", followed), false);
  assert.equal(isInside("/w/repo", "../x", followed), false);
});

test("a grant matches repos without case, and no grant means no limit", () => {
  assert.equal(inGrant("Acme/API", ["acme/api"]), true);
  assert.equal(inGrant("acme/old", ["acme/api"]), false);
  assert.equal(inGrant("acme/old", null), true);
  assert.equal(inGrant("acme/old", undefined), true);
});

test("the tool names offer clone_repo and github_api only with a token", () => {
  assert.deepEqual(readToolNames(false), [
    "mcp__prhub__git",
    "mcp__prhub__draft_review",
    "mcp__prhub__github_act",
    "mcp__prhub__linear_act",
  ]);
  assert.deepEqual(readToolNames(true), [
    "mcp__prhub__git",
    "mcp__prhub__clone_repo",
    "mcp__prhub__github_api",
    "mcp__prhub__draft_review",
    "mcp__prhub__github_act",
    "mcp__prhub__linear_act",
  ]);
});
