// Ask's read tools on disk: real git in temporary folders, and the hook following real symlinks.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { onTestFinished, test } from "vitest";
import { WRITERS } from "../fixtures/git-arguments.mjs";
import { gitEnv, readOnlyHooks, readTools, runGit } from "../../read-tools.mjs";

// Setup Git with the same isolated environment as the tool, independent of the operator's config.
const gitFree = gitEnv();

function temporaryRoot() {
  const root = mkdtempSync(`${tmpdir()}/ask-`);
  onTestFinished(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

async function decide(hooks, tool_name, tool_input) {
  const output = await hooks[0].hooks[0]({ tool_name, tool_input });
  return output.hookSpecificOutput?.permissionDecision ?? "allow";
}

test("the hook follows symlinks on disk: reads stay in the checkout and the clones", async () => {
  const root = temporaryRoot();
  const cwd = `${root}/acme/api/7`;
  const clones = `${root}/.clones`;
  mkdirSync(cwd, { recursive: true });
  mkdirSync(`${clones}/acme/actions`, { recursive: true });
  symlinkSync("/etc", `${cwd}/out`);
  const hooks = readOnlyHooks(cwd, clones);
  assert.equal(await decide(hooks, "Read", { file_path: `${cwd}/src/a.ts` }), "allow");
  assert.equal(
    await decide(hooks, "Read", { file_path: `${clones}/acme/actions/action.yml` }),
    "allow",
  );
  assert.equal(
    await decide(hooks, "Grep", { pattern: "x", path: `${clones}/acme/actions` }),
    "allow",
  );
  assert.equal(await decide(hooks, "Read", { file_path: "/proc/self/environ" }), "deny");
  assert.equal(
    await decide(hooks, "Read", { file_path: `${cwd}/out/passwd` }),
    "deny",
    "a symlink out is outside",
  );
});

test("the git tool runs a read in the checkout, refuses a write itself, and keeps no token in what it says", async () => {
  const root = temporaryRoot();
  const cwd = `${root}/acme/api/7`;
  mkdirSync(cwd, { recursive: true });
  const run = (...args) => execFileSync("git", ["-C", cwd, ...args], { env: gitFree });
  run("init", "-q");
  writeFileSync(`${cwd}/a.txt`, "secret-token-value\n");
  run("add", "a.txt");
  run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first");
  const server = readTools({
    prDir: cwd,
    prRepo: "acme/api",
    clones: `${root}/.clones`,
    scope: root,
    token: null,
    locked: (_, f) => f(),
  });
  const git = server.instance._registeredTools?.git ?? null;
  assert.ok(git, "git is offered without a token");
  assert.equal(
    server.instance._registeredTools.github_api,
    undefined,
    "no API without a read-only token",
  );
  for (const name of ["draft_review", "github_act", "linear_act"]) {
    assert.ok(server.instance._registeredTools[name], `${name} is offered without a token`);
  }
  const call = (args) => (git.handler ?? git.callback)(args, {});
  const log = await call({ args: ["log", "--format=%s"] });
  assert.equal(log.content[0].text.trim(), "first");
  const push = await call({ args: ["push", "origin", "HEAD"] });
  assert.equal(push.isError, true);
  const withToken = readTools({
    prDir: cwd,
    prRepo: "acme/api",
    clones: `${root}/.clones`,
    scope: root,
    token: "secret-token-value",
    locked: (_, f) => f(),
  });
  const show = await (
    withToken.instance._registeredTools.git.handler ??
    withToken.instance._registeredTools.git.callback
  )({ args: ["show", "HEAD:a.txt"] }, {});
  assert.equal(show.content[0].text.trim(), "[redacted]");
});

/** A scope with the PR's checkout, a committed file and a committed symlink out, and the git tool on it. */
function scopeWithLink() {
  const root = temporaryRoot();
  const cwd = `${root}/acme/api/7`;
  mkdirSync(cwd, { recursive: true });
  const run = (...args) => execFileSync("git", ["-C", cwd, ...args], { env: gitFree });
  run("init", "-q");
  writeFileSync(`${cwd}/a.txt`, "one\n");
  symlinkSync("/etc/hosts", `${cwd}/link`);
  symlinkSync("/etc", `${cwd}/dir`);
  run("add", "a.txt", "link", "dir");
  run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first");
  const server = readTools({
    prDir: cwd,
    prRepo: "acme/api",
    clones: `${root}/.clones`,
    scope: root,
    token: null,
    locked: (_, f) => f(),
  });
  const git = server.instance._registeredTools.git;
  return { root, cwd, call: (args, repo) => (git.handler ?? git.callback)({ args, repo }, {}) };
}

test("blame's file options and a committed symlink out of the repo are refused before git runs", async () => {
  const { call } = scopeWithLink();
  for (const args of [
    ["blame", "-S", "link", "--", "a.txt"],
    ["blame", "--ignore-revs-file=link", "a.txt"],
    ["blame", "--ignore-revs-f=link", "a.txt"],
    ["blame", "--", "link"],
    ["log", "--", "dir/hosts"],
    ["diff", "link"],
  ]) {
    const answer = await call(args);
    assert.equal(answer.isError, true, JSON.stringify(args));
    assert.doesNotMatch(answer.content[0].text, /localhost|bad graft/, JSON.stringify(args));
  }
  const fine = await call(["blame", "--", "a.txt"]);
  assert.equal(fine.isError, false);
});

test("git has an empty stdin, so a command that would read it ends at once", async () => {
  const { cwd } = scopeWithLink();
  const answer = await runGit(cwd, ["shortlog"], null, 10_000);
  assert.equal(answer.ok, true);
});

test("the exploits change no .git/config, and no allowed command does", async () => {
  const { cwd, call } = scopeWithLink();
  const config = `${cwd}/.git/config`;
  const before = readFileSync(config, "utf8");
  for (const args of WRITERS) {
    const answer = await call(args);
    assert.equal(answer.isError, true, JSON.stringify(args));
  }
  const allowed = [
    ["log", "--pretty", "-1"],
    ["log", "--oneline", "-n", "5", "--stat"],
    ["show", "--abbrev", "HEAD"],
    ["diff", "-U5"],
    ["diff", "--abbrev", "--stat"],
    ["grep", "-n", "one"],
    ["blame", "--", "a.txt"],
    ["shortlog", "-s", "HEAD"],
    ["describe", "--always", "--abbrev=8"],
    ["rev-parse", "--short", "HEAD"],
    ["rev-list", "--count", "HEAD"],
    ["ls-files", "--stage"],
    ["ls-tree", "-r", "--abbrev", "HEAD"],
    ["cat-file", "-p", "HEAD"],
    ["for-each-ref", "--format=%(refname)"],
    ["name-rev", "HEAD"],
    ["merge-base", "--all", "HEAD", "HEAD"],
  ];
  for (const args of allowed) {
    const answer = await call(args);
    assert.equal(answer.isError, false, `${JSON.stringify(args)}: ${answer.content[0].text}`);
    assert.equal(readFileSync(config, "utf8"), before, JSON.stringify(args));
  }
});

test("a repo config that names a program runs nothing: every git call overrides it", async () => {
  const { cwd, call } = scopeWithLink();
  const marker = `${cwd}/../ran`;
  writeFileSync(
    `${cwd}/.git/config`,
    `${readFileSync(`${cwd}/.git/config`, "utf8")}
[core]
\tfsmonitor = "touch ${marker}"
\tpager = "touch ${marker}"
[diff]
\texternal = "touch ${marker}"
`,
  );
  writeFileSync(`${cwd}/a.txt`, "changed\n");
  for (const args of [["diff"], ["log", "-p", "-1"], ["show"], ["grep", "x"]]) {
    const answer = await call(args);
    // grep exits 1 when no match exists; all other reads must actually succeed.
    if (args[0] !== "grep") {
      assert.equal(answer.isError, false, answer.content[0].text);
    }
  }
  assert.throws(
    () => statSync(marker),
    { code: "ENOENT" },
    "no program from the repo's config ran",
  );
});
