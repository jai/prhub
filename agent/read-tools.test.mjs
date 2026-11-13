// Ask's read tools: the hook lets reads through and denies writes, pushes, other methods and paths outside.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import test from "node:test";
import { readOnlyHooks, readTools, runGit, vetApiPath, vetGit, vetRepo, vetRef } from "./read-tools.mjs";

test("git reads pass", () => {
  for (const args of [
    ["log", "--oneline", "-20"], ["show", "HEAD:src/a.ts"], ["diff", "main..HEAD", "--", "src"], ["grep", "-n", "retry"],
    ["blame", "-L", "10,20", "src/a.ts"], ["for-each-ref", "--contains", "abc123", "refs/tags"], ["describe", "--tags"],
    ["grep", "-c", "x"], ["grep", "-n", "-e", "retry", "--", "src"], ["log", "-S", "retry", "-5"], ["log", "--format=%H %s"],
    ["blame", "-L", "1,5", "--", "a.txt"], ["for-each-ref", "--contains", "HEAD", "--format=%(refname)"],
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
    // The review's exploits: blame reads its -S and --ignore-revs-file and echoes them as "bad graft data".
    ["blame", "-S", "/proc/self/environ", "a"], ["blame", "-Sx", "a"], ["blame", "-S", "link", "--", "f"],
    ["blame", "--ignore-revs-file=x", "a"], ["blame", "--ignore-revs-f=x", "a"], ["blame", "--ignore-revs-file", "x", "a"],
    // Any option off the list, and every abbreviation of one on it.
    ["log", "--output-indicator-new=+"], ["log", "--onelin"], ["log", "--textconv"], ["cat-file", "--batch"],
    ["grep", "--no-index", "x"], ["log", "--grep"],
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
  const server = readTools({
    prDir: cwd, prRepo: "acme/api", clones: `${root}/.clones`, scope: root, token: null, locked: (_, f) => f(),
  });
  const git = server.instance._registeredTools?.git ?? null;
  assert.ok(git, "git is offered without a token");
  assert.equal(server.instance._registeredTools.github_api, undefined, "no API without a read-only token");
  const call = (args) => (git.handler ?? git.callback)(args, {});
  const log = await call({ args: ["log", "--format=%s"] });
  assert.equal(log.content[0].text.trim(), "first");
  const push = await call({ args: ["push", "origin", "HEAD"] });
  assert.equal(push.isError, true);
  const withToken = readTools({
    prDir: cwd, prRepo: "acme/api", clones: `${root}/.clones`, scope: root, token: "secret-token-value",
    locked: (_, f) => f(),
  });
  const show = await (withToken.instance._registeredTools.git.handler ?? withToken.instance._registeredTools.git.callback)(
    { args: ["show", "HEAD:a.txt"] }, {});
  assert.equal(show.content[0].text.trim(), "[redacted]");
});

test("a repo the token can't reach answers that the reviewer can't access it", async () => {
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => new Response('{"message":"Not Found"}', { status: String(url).includes("/secret") ? 404 : 200 });
  try {
    const server = readTools({
      prDir: tmpdir(), prRepo: "acme/api", clones: tmpdir(), scope: tmpdir(), token: "fake-install-token",
      locked: (_, f) => f(),
    });
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

/** A scope with the PR's checkout, a committed file and a committed symlink out, and the git tool on it. */
function scopeWithLink() {
  const root = mkdtempSync(`${tmpdir()}/ask-`);
  const cwd = `${root}/acme/api/7`;
  mkdirSync(cwd, { recursive: true });
  const run = (...args) => execFileSync("git", ["-C", cwd, ...args]);
  run("init", "-q");
  writeFileSync(`${cwd}/a.txt`, "one\n");
  symlinkSync("/etc/hosts", `${cwd}/link`);
  symlinkSync("/etc", `${cwd}/dir`);
  run("add", "a.txt", "link", "dir");
  run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first");
  const server = readTools({ prDir: cwd, prRepo: "acme/api", clones: `${root}/.clones`, scope: root, token: null,
    locked: (_, f) => f() });
  const git = server.instance._registeredTools.git;
  return { root, cwd, call: (args, repo) => (git.handler ?? git.callback)({ args, repo }, {}) };
}

test("blame's file options and a committed symlink out of the repo are refused before git runs", async () => {
  const { call } = scopeWithLink();
  for (const args of [["blame", "-S", "link", "--", "a.txt"], ["blame", "--ignore-revs-file=link", "a.txt"],
    ["blame", "--ignore-revs-f=link", "a.txt"], ["blame", "--", "link"], ["log", "--", "dir/hosts"], ["diff", "link"]]) {
    const answer = await call(args);
    assert.equal(answer.isError, true, JSON.stringify(args));
    assert.doesNotMatch(answer.content[0].text, /localhost|bad graft/, JSON.stringify(args));
  }
  const fine = await call(["blame", "--", "a.txt"]);
  assert.equal(fine.isError, false);
});

test("git has an empty stdin, so a command that would read it ends at once", async () => {
  const { cwd } = scopeWithLink();
  const started = Date.now();
  const answer = await runGit(cwd, ["shortlog"], null, 10_000);
  assert.ok(Date.now() - started < 5_000, "shortlog with no revision reads stdin; it must not wait for it");
  assert.equal(answer.ok, true);
});

test("hosted, a clone outside this question's grant can't be read, gitted or made", async () => {
  const root = mkdtempSync(`${tmpdir()}/ask-`);
  const cwd = `${root}/acme/api/7`;
  const clones = `${root}/.clones`;
  mkdirSync(cwd, { recursive: true });
  mkdirSync(`${clones}/acme/actions`, { recursive: true });
  mkdirSync(`${clones}/acme/old`, { recursive: true });
  const hooks = readOnlyHooks(cwd, clones, ["acme/api", "Acme/Actions"]);
  assert.equal(await decide(hooks, "Read", { file_path: `${clones}/acme/actions/action.yml` }), "allow");
  assert.equal(await decide(hooks, "Read", { file_path: `${clones}/acme/old/secret.yml` }), "deny", "access since lost");
  assert.equal(await decide(hooks, "Grep", { pattern: "x", path: clones }), "deny", "not the clones as a whole");
  assert.equal(await decide(hooks, "mcp__prhub__git", { args: ["log"], repo: "acme/old" }), "deny");
  assert.equal(await decide(hooks, "mcp__prhub__clone_repo", { repo: "acme/old" }), "deny");
  assert.equal(await decide(hooks, "mcp__prhub__clone_repo", { repo: "acme/actions" }), "allow");
  const server = readTools({ prDir: cwd, prRepo: "acme/api", clones, scope: root, token: "fake-install-token",
    locked: (_, f) => f(), reachable: ["acme/api"] });
  const tools = server.instance._registeredTools;
  const gitOld = await (tools.git.handler ?? tools.git.callback)({ args: ["log"], repo: "acme/old" }, {});
  assert.match(gitOld.content[0].text, /can't access acme\/old/);
  const cloneOld = await (tools.clone_repo.handler ?? tools.clone_repo.callback)({ repo: "acme/old" }, {});
  assert.match(cloneOld.content[0].text, /can't access acme\/old/);
});

test("tool output never carries the subscription token either", async () => {
  const { cwd, call } = scopeWithLink();
  const saved = process.env.CLAUDE_CODE_OAUTH_TOKEN;
  process.env.CLAUDE_CODE_OAUTH_TOKEN = "sk-subscription-value";
  try {
    writeFileSync(`${cwd}/a.txt`, "sk-subscription-value\n");
    const answer = await call(["diff"]);
    assert.doesNotMatch(answer.content[0].text, /sk-subscription-value/);
    assert.match(answer.content[0].text, /\[redacted\]/);
  } finally {
    if (saved === undefined) {
      delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
    } else {
      process.env.CLAUDE_CODE_OAUTH_TOKEN = saved;
    }
  }
});
