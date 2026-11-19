import assert from "node:assert/strict";
import { test, vi } from "vitest";
import { z } from "zod";
import {
  authArgs,
  checkoutTargets,
  DRAFT_COMMENTS,
  gitArgv,
  gitCommand,
  gitEnv,
  INPUTS,
  SAFE_GIT,
  vetApiPath,
  vetGit,
  vetRepo,
  vetRef,
} from "../../vet.mjs";
import { WRITERS } from "../fixtures/git-arguments.mjs";

test("git reads pass", () => {
  for (const args of [
    ["log", "--oneline", "-20"],
    ["show", "HEAD:src/a.ts"],
    ["diff", "main..HEAD", "--", "src"],
    ["grep", "-n", "retry"],
    ["blame", "-L", "10,20", "src/a.ts"],
    ["for-each-ref", "--contains", "abc123", "refs/tags"],
    ["describe", "--tags"],
    ["grep", "--count", "x"],
    ["grep", "-n", "-e", "retry", "--", "src"],
    ["log", "--pretty", "-1"],
    ["log", "--pretty=%H"],
    ["diff", "--abbrev", "--stat"],
    ["diff", "-U5"],
    ["log", "-n", "5"],
    ["ls-tree", "--abbrev=8", "HEAD"],
    ["log", "-S", "retry", "-5"],
    ["log", "--format=%H %s"],
    ["blame", "-L", "1,5", "--", "a.txt"],
    ["for-each-ref", "--contains", "HEAD", "--format=%(refname)"],
  ]) {
    assert.equal(vetGit(args), null, args.join(" "));
  }
});

test("git writes, pushes, programs and outside paths are denied", () => {
  for (const args of [
    ["push", "origin", "main"],
    ["commit", "-m", "x"],
    ["fetch", "origin"],
    ["checkout", "main"],
    ["config", "a.b", "c"],
    ["tag", "v9"],
    ["branch", "-D", "main"],
    ["-c", "core.pager=sh", "log"],
    ["--git-dir=/tmp", "log"],
    ["log", "--output=/tmp/x"],
    ["log", "--outp=/tmp/x"],
    ["diff", "--no-index", "a", "b"],
    ["diff", "/proc/self/environ", "/dev/null"],
    ["show", "../../etc/passwd"],
    ["grep", "-O", "sh", "x"],
    ["grep", "-nf", "/etc/passwd"],
    ["blame", "--contents", "x", "a"],
    ["diff", "--ext-diff"],
    [],
    "log",
    // The review's exploits: blame reads its -S and --ignore-revs-file and echoes them as "bad graft data".
    ["blame", "-S", "/proc/self/environ", "a"],
    ["blame", "-Sx", "a"],
    ["blame", "-S", "link", "--", "f"],
    ["blame", "-S", "link", "--", "a.txt"],
    ["blame", "--ignore-revs-file=link", "a.txt"],
    ["blame", "--ignore-revs-f=link", "a.txt"],
    ["blame", "--ignore-revs-file=x", "a"],
    ["blame", "--ignore-revs-f=x", "a"],
    ["blame", "--ignore-revs-file", "x", "a"],
    // Any option off the list, and every abbreviation of one on it.
    ["log", "--output-indicator-new=+"],
    ["log", "--onelin"],
    ["log", "--textconv"],
    ["cat-file", "--batch"],
    ["grep", "--no-index", "x"],
    ["log", "--grep"],
  ]) {
    assert.notEqual(vetGit(args), null, JSON.stringify(args));
  }
});

test("only GETs of api.github.com paths", () => {
  assert.equal(vetApiPath("/repos/acme/api/pulls/1/reviews?per_page=100"), null);
  assert.equal(vetApiPath("/repos/acme/actions/releases/latest"), null);
  for (const path of [
    "https://evil.example/x",
    "//evil.example/x",
    "/repos/../user",
    "/x@evil",
    "repos/a/b",
    "/a b",
  ]) {
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

test("no spelling of a writer or runner passes, wherever it appears", () => {
  for (const args of WRITERS) {
    assert.notEqual(vetGit(args), null, JSON.stringify(args));
  }
});

test("every git call turns off the repo's programs, ssh and every protocol but https", () => {
  const settings = SAFE_GIT.filter((_, at) => at % 2 === 1);
  assert.ok(SAFE_GIT.every((arg, at) => at % 2 === 1 || arg === "-c"));
  assert.deepEqual(settings, [
    "core.fsmonitor=false",
    "core.hooksPath=/dev/null",
    "core.pager=cat",
    "core.editor=false",
    "core.sshCommand=false",
    "protocol.allow=never",
    "protocol.https.allow=always",
  ]);
});

test("the token rides one command's header, and the safe settings come before anything asked for", () => {
  assert.deepEqual(authArgs(null), []);
  assert.deepEqual(authArgs(""), []);
  assert.deepEqual(authArgs("ghs-abc"), [
    "-c",
    `http.extraHeader=Authorization: Basic ${Buffer.from("x-access-token:ghs-abc").toString("base64")}`,
  ]);
  assert.deepEqual(gitArgv("/w/repo", ["log"], null), ["-C", "/w/repo", ...SAFE_GIT, "log"]);
  assert.deepEqual(gitArgv("/w/repo", ["log"], "ghs-abc"), [
    "-C",
    "/w/repo",
    ...SAFE_GIT,
    ...authArgs("ghs-abc"),
    "log",
  ]);
});

test("reads that could run a diff or textconv program get the options that turn it off", () => {
  assert.deepEqual(gitCommand(["log", "-p"]), ["log", "--no-ext-diff", "--no-textconv", "-p"]);
  assert.deepEqual(gitCommand(["show"]), ["show", "--no-ext-diff", "--no-textconv"]);
  assert.deepEqual(gitCommand(["diff", "a"]), ["diff", "--no-ext-diff", "--no-textconv", "a"]);
  assert.deepEqual(gitCommand(["blame", "a"]), ["blame", "--no-textconv", "a"]);
  assert.deepEqual(gitCommand(["grep", "x"]), ["grep", "--no-textconv", "x"]);
  assert.deepEqual(gitCommand(["rev-parse", "HEAD"]), ["rev-parse", "HEAD"]);
});

test("git's environment carries PATH and none of this process's secrets or config", () => {
  vi.stubEnv("PATH", "/bin");
  vi.stubEnv("CLAUDE_CODE_OAUTH_TOKEN", "sk-sub");
  vi.stubEnv("GIT_DIR", "/elsewhere");
  assert.deepEqual(gitEnv(), {
    PATH: "/bin",
    HOME: "/nonexistent",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_TERMINAL_PROMPT: "0",
    GIT_PAGER: "cat",
    PAGER: "cat",
    GIT_OPTIONAL_LOCKS: "0",
  });
});

test("a clone checks out the default branch, a branch or tag as origin's or as written, and fetches a commit first", () => {
  assert.deepEqual(checkoutTargets(undefined), { fetch: null, targets: ["origin/HEAD"] });
  assert.deepEqual(checkoutTargets("v2"), { fetch: null, targets: ["origin/v2", "v2"] });
  const sha = "a".repeat(40);
  assert.deepEqual(checkoutTargets(sha), { fetch: sha, targets: [`origin/${sha}`, sha] });
  assert.equal(checkoutTargets("a".repeat(39)).fetch, null, "a short commit is not fetched alone");
});

test("each tool's input shape takes what the tool says and refuses the rest", () => {
  const parse = (name, input) => z.object(INPUTS[name]).safeParse(input).success;
  assert.equal(parse("git", { args: ["log"] }), true);
  assert.equal(parse("git", { args: [] }), false);
  assert.equal(parse("git", { args: [1] }), false);
  assert.equal(parse("clone_repo", { repo: "acme/a", ref: "v1" }), true);
  assert.equal(parse("clone_repo", {}), false);
  assert.equal(parse("github_api", { path: "/repos/a/b" }), true);
  assert.equal(parse("github_api", {}), false);
  const comment = { path: "a.ts", line: 3, side: "RIGHT", body: "x" };
  assert.equal(
    parse("draft_review", { event: "APPROVE", body: "" }),
    true,
    "comments default to none",
  );
  assert.deepEqual(
    z.object(INPUTS.draft_review).parse({ event: "COMMENT", body: "" }).comments,
    [],
  );
  assert.equal(parse("draft_review", { event: "MERGE", body: "" }), false);
  assert.equal(
    parse("draft_review", { event: "COMMENT", body: "", comments: [{ ...comment, line: 0 }] }),
    false,
  );
  assert.equal(
    parse("draft_review", { event: "COMMENT", body: "", comments: [{ ...comment, line: 1.5 }] }),
    false,
  );
  assert.equal(
    parse("draft_review", { event: "COMMENT", body: "", comments: [{ ...comment, side: "UP" }] }),
    false,
  );
  assert.equal(
    parse("draft_review", { event: "COMMENT", body: "", comments: [{ ...comment, body: "" }] }),
    false,
  );
  const many = (count) => ({ event: "COMMENT", body: "", comments: Array(count).fill(comment) });
  assert.equal(parse("draft_review", many(DRAFT_COMMENTS)), true);
  assert.equal(parse("draft_review", many(DRAFT_COMMENTS + 1)), false);
  assert.equal(parse("draft_review", { event: "COMMENT", body: "x".repeat(20_001) }), false);
  assert.equal(parse("github_act", { action: { kind: "comment", body: "x" } }), true);
  assert.equal(parse("github_act", { action: "merge" }), false);
  assert.equal(parse("linear_act", { issue: "ENG-12", body: "x" }), true);
  assert.equal(parse("linear_act", { issue: "eng-12", body: "x" }), true);
  for (const issue of ["ENG12", "12-ENG", "ENG-", "ABCDEFGHIJK-1", "ENG-1 x"]) {
    assert.equal(parse("linear_act", { issue, body: "x" }), false, issue);
  }
  assert.equal(parse("linear_act", { issue: "ENG-1", body: "" }), false);
});
