import assert from "node:assert/strict";
import { test } from "vitest";
import { vetApiPath, vetGit, vetRepo, vetRef } from "../../vet.mjs";
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
