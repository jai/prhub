// Ask's read tools: the hook lets reads through and denies writes, pushes, other methods and paths outside.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import test from "node:test";
import { readOnlyHooks, readTools, vetApiPath, vetGit, vetRepo, vetRef } from "./read-tools.mjs";

test("git reads pass", () => {
  for (const args of [
    ["log", "--oneline", "-20"], ["show", "HEAD:src/a.ts"], ["diff", "main..HEAD", "--", "src"], ["grep", "-n", "retry"],
    ["blame", "-L", "10,20", "src/a.ts"], ["for-each-ref", "--contains", "abc123", "refs/tags"], ["describe", "--tags"],
    ["log", "--output-indicator-new=+"], ["grep", "-c", "x"],
  ]) {
    assert.equal(vetGit(args), null, args.join(" "));
  }
});

test("git writes, pushes, programs and outside paths are denied", () => {
  for (const args of [
    ["push", "origin", "main"], ["commit", "-m", "x"], ["fetch", "origin"], ["checkout", "main"], ["config", "a.b", "c"],
    ["tag", "v9"], ["branch", "-D", "main"], ["-c", "core.pager=sh", "log"], ["--git-dir=/tmp", "log"],
    ["log", "--output=/tmp/x"], ["log", "--outp=/tmp/x"], ["diff", "--no-index", "a", "b"],
    ["diff", "/proc/self/environ", "/dev/null"], ["show", "../../etc/passwd"], ["grep", "-O", "sh", "x"],
    ["grep", "-nf", "/etc/passwd"], ["blame", "--contents", "x", "a"], ["diff", "--ext-diff"], [], "log",
  ]) {
    assert.notEqual(vetGit(args), null, JSON.stringify(args));
  }
});

test("only GETs of api.github.com paths", () => {
  assert.equal(vetApiPath("/repos/acme/api/pulls/1/reviews?per_page=100"), null);
  assert.equal(vetApiPath("/repos/acme/actions/releases/latest"), null);
  for (const path of ["https://evil.example/x", "//evil.example/x", "/repos/../user", "/x@evil", "repos/a/b", "/a b"]) {
    assert.notEqual(vetApiPath(path), null, path);
  }
});

test("repos and refs are named, never paths", () => {
  assert.equal(vetRepo("acme/actions"), null);
  assert.equal(vetRef("v1.2.3"), null);
  assert.equal(vetRef(undefined), null);
  for (const repo of ["acme", "../x/y", "acme/..", "acme/a/b", "-x/y"]) {
    assert.notEqual(vetRepo(repo), null, repo);
  }
  for (const ref of ["--upload-pack=sh", "a..b", "a b"]) {
    assert.notEqual(vetRef(ref), null, ref);
  }
});

async function decide(hooks, tool_name, tool_input) {
  const output = await hooks[0].hooks[0]({ tool_name, tool_input });
  return output.hookSpecificOutput?.permissionDecision ?? "allow";
}

test("the hook allows reads in the checkout and the clones, and denies everything else", async () => {
  const root = mkdtempSync(`${tmpdir()}/ask-`);
  const cwd = `${root}/acme/api/7`;
  const clones = `${root}/.clones`;
  mkdirSync(cwd, { recursive: true });
  mkdirSync(`${clones}/acme/actions`, { recursive: true });
  symlinkSync("/etc", `${cwd}/out`);
  const hooks = readOnlyHooks(cwd, clones);
  assert.equal(await decide(hooks, "Read", { file_path: `${cwd}/src/a.ts` }), "allow");
  assert.equal(await decide(hooks, "Read", { file_path: `${clones}/acme/actions/action.yml` }), "allow");
  assert.equal(await decide(hooks, "Grep", { pattern: "x", path: `${clones}/acme/actions` }), "allow");
  assert.equal(await decide(hooks, "mcp__prhub__git", { args: ["log", "-5"], repo: "acme/actions" }), "allow");
  assert.equal(await decide(hooks, "mcp__prhub__clone_repo", { repo: "acme/actions", ref: "v2" }), "allow");
  assert.equal(await decide(hooks, "mcp__prhub__github_api", { path: "/repos/acme/api/pulls/7/comments" }), "allow");
  assert.equal(await decide(hooks, "Read", { file_path: "/proc/self/environ" }), "deny");
  assert.equal(await decide(hooks, "Read", { file_path: `${cwd}/out/passwd` }), "deny", "a symlink out is outside");
  assert.equal(await decide(hooks, "Glob", { pattern: "/etc/*" }), "deny");
  assert.equal(await decide(hooks, "mcp__prhub__git", { args: ["push", "origin", "HEAD"] }), "deny");
  assert.equal(await decide(hooks, "mcp__prhub__github_api", { path: "https://evil.example/" }), "deny");
  assert.equal(await decide(hooks, "Bash", { command: "cat /proc/self/environ" }), "deny");
  assert.equal(await decide(hooks, "Write", { file_path: `${cwd}/a` }), "deny");
});

test("the git tool runs a read in the checkout, refuses a write itself, and keeps no token in what it says", async () => {
  const root = mkdtempSync(`${tmpdir()}/ask-`);
  const cwd = `${root}/acme/api/7`;
  mkdirSync(cwd, { recursive: true });
  const run = (...args) => execFileSync("git", ["-C", cwd, ...args]);
  run("init", "-q");
  writeFileSync(`${cwd}/a.txt`, "secret-token-value\n");
  run("add", "a.txt");
  run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first");
  const server = readTools({ prDir: cwd, prRepo: "acme/api", clones: `${root}/.clones`, token: null, locked: (_, f) => f() });
  const git = server.instance._registeredTools?.git ?? null;
  assert.ok(git, "git is offered without a token");
  assert.equal(server.instance._registeredTools.github_api, undefined, "no API without a read-only token");
  const call = (args) => (git.handler ?? git.callback)(args, {});
  const log = await call({ args: ["log", "--format=%s"] });
  assert.equal(log.content[0].text.trim(), "first");
  const push = await call({ args: ["push", "origin", "HEAD"] });
  assert.equal(push.isError, true);
  const withToken = readTools({
    prDir: cwd, prRepo: "acme/api", clones: `${root}/.clones`, token: "secret-token-value", locked: (_, f) => f(),
  });
  const show = await (withToken.instance._registeredTools.git.handler ?? withToken.instance._registeredTools.git.callback)(
    { args: ["show", "HEAD:a.txt"] }, {});
  assert.equal(show.content[0].text.trim(), "[redacted]");
});

test("a repo the token can't reach answers that the reviewer can't access it", async () => {
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => new Response('{"message":"Not Found"}', { status: String(url).includes("/secret") ? 404 : 200 });
  try {
    const server = readTools({ prDir: tmpdir(), prRepo: "acme/api", clones: tmpdir(), token: "fake-install-token", locked: (_, f) => f() });
    const api = server.instance._registeredTools.github_api;
    const call = (path) => (api.handler ?? api.callback)({ path }, {});
    const denied = await call("/repos/acme/secret/releases/latest");
    assert.equal(denied.isError, true);
    assert.match(denied.content[0].text, /can't access acme\/secret: the reviewer can't see it, or the GitHub App isn't installed/);
    const fine = await call("/repos/acme/actions/releases/latest");
    assert.equal(fine.isError, false);
  } finally {
    globalThis.fetch = real;
  }
});
