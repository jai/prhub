// node --test release/version.test.mjs — PRHub's version from conventional commits, and its tag and Release on a
// stubbed GitHub.
import assert from "node:assert/strict";
import { test } from "node:test";
import { githubClient } from "./cadence.mjs";
import { bumpOf, newestTag, notesFor, planVersion, publishVersion } from "./version.mjs";

const HEAD = "h".repeat(40);
const c = (subject, body = "") => ({ subject, body });
const plan = (commits, tags = ["v0.17.4", "v0.17.3"], headTags = []) => {
  const since = [];
  const result = planVersion({ tags, headTags, commitsSince: (tag) => (since.push(tag), commits) });
  return { ...result, since };
};

test("the newest tag is the highest vX.Y.Z, not the last listed", () => {
  assert.equal(newestTag(["v0.9.0", "v0.17.4", "v0.10.2", "v1.0.0-rc1", "prkit-2"]), "v0.17.4");
  assert.equal(newestTag(["v0.17.10", "v0.17.9"]), "v0.17.10");
  assert.equal(newestTag([]), null);
});

test("below 1.0.0: feat bumps the minor", () => {
  const p = plan([c("fix(app): a"), c("feat(prkit): b"), c("chore: c")]);
  assert.deepEqual([p.action, p.tag, p.since[0]], ["tag", "v0.18.0", "v0.17.4"]);
});

test("below 1.0.0: fix and perf bump the patch", () => {
  assert.equal(plan([c("fix: a")]).tag, "v0.17.5");
  assert.equal(plan([c("perf(app): a"), c("docs: b")]).tag, "v0.17.5");
});

test("a breaking change bumps the minor below 1.0.0 and the major from 1.0.0", () => {
  assert.equal(plan([c("refactor(prkit)!: a")]).tag, "v0.18.0");
  assert.equal(plan([c("fix: a", "Details.\n\nBREAKING CHANGE: the API moved")]).tag, "v0.18.0");
  assert.equal(plan([c("feat!: a")], ["v1.4.2"]).tag, "v2.0.0");
  assert.equal(bumpOf([1, 4, 2], [c("feat: a")]), "minor");
  assert.equal(bumpOf([1, 4, 2], [c("fix: a")]), "patch");
});

test("only chore, docs, ci or test: the version stays and no tag is made", () => {
  const p = plan([c("chore: a"), c("docs(api): b"), c("ci: c"), c("test: d"), c("Merge something")]);
  assert.deepEqual([p.action, p.tag, p.version], ["keep", "v0.17.4", "0.17.4"]);
});

test("a head that already has a v-tag reuses it and reads no commits", () => {
  const p = plan([c("feat: a")], ["v0.17.4"], ["v0.17.4"]);
  assert.deepEqual([p.action, p.tag, p.version, p.since.length], ["reuse", "v0.17.4", "0.17.4", 0]);
});

test("no tag at all starts from 0.0.0", () => {
  const p = plan([c("feat: a")], []);
  assert.deepEqual([p.tag, p.since[0]], ["v0.1.0", null]);
});

test("notes list feats then fixes and perf, as subjects", () => {
  const notes = notesFor([c("fix(app): one"), c("chore: no"), c("feat(prkit): two"), c("perf: three"), c("x!: four")]);
  assert.equal(notes, "- feat(prkit): two\n- x!: four\n- fix(app): one\n- perf: three");
});

function stubGitHub({ releases = {} } = {}) {
  const calls = [];
  const fetchImpl = async (url, { method, headers, body }) => {
    const path = url.replace("https://api.github.com/repos/jai/prhub/", "");
    calls.push({ method, path, body: body && JSON.parse(body), auth: headers.Authorization });
    const json = (status, value) => ({ ok: status < 300, status, text: async () => JSON.stringify(value) });
    if (method === "GET" && path.startsWith("releases/tags/")) {
      const tag = decodeURIComponent(path.slice("releases/tags/".length));
      return releases[tag] ? json(200, releases[tag]) : json(404, { message: "Not Found" });
    }
    if (method === "POST" && path === "git/tags") return json(201, { sha: "tagobject" });
    if (method === "POST" && path === "git/refs") return json(201, {});
    if (method === "POST" && path === "releases") return json(201, { html_url: "https://github.com/jai/prhub/releases/x" });
    throw new Error(`unexpected ${method} ${path}`);
  };
  return { calls, github: githubClient({ token: "t0ken", repository: "jai/prhub", fetchImpl }) };
}

test("a new version: an annotated tag on the head, its ref, then a Release with the notes", async () => {
  const { calls, github } = stubGitHub();
  const notes = "- feat: a\n- fix: b";
  const line = await publishVersion(github, { action: "tag", tag: "v0.18.0", version: "0.18.0", notes }, HEAD);
  assert.deepEqual(
    calls.map(({ method, path, body }) => [method, path, body]),
    [
      ["POST", "git/tags", { tag: "v0.18.0", message: notes, object: HEAD, type: "commit" }],
      ["POST", "git/refs", { ref: "refs/tags/v0.18.0", sha: "tagobject" }],
      ["GET", "releases/tags/v0.18.0", undefined],
      ["POST", "releases", { tag_name: "v0.18.0", name: "v0.18.0", body: notes }],
    ],
  );
  assert.ok(calls.every(({ auth }) => auth === "Bearer t0ken"));
  assert.match(line, /tagged v0\.18\.0/);
});

test("a reused tag gets a Release only if it has none; a kept version calls nothing", async () => {
  const reuse = { action: "reuse", tag: "v0.17.4", version: "0.17.4" };
  const had = stubGitHub({ releases: { "v0.17.4": { id: 1 } } });
  await publishVersion(had.github, reuse, HEAD, () => "unused");
  assert.deepEqual(had.calls.map(({ method }) => method), ["GET"]);
  const missing = stubGitHub();
  await publishVersion(missing.github, reuse, HEAD, () => "PRKit 0.17.4: notes");
  assert.deepEqual(missing.calls.at(-1).body, { tag_name: "v0.17.4", name: "v0.17.4", body: "PRKit 0.17.4: notes" });
  const kept = stubGitHub();
  await publishVersion(kept.github, { action: "keep", tag: "v0.17.4", version: "0.17.4" }, HEAD);
  assert.deepEqual(kept.calls, []);
});

test("a failed GitHub call throws with its status", async () => {
  const github = githubClient({
    token: "t", repository: "jai/prhub",
    fetchImpl: async () => ({ ok: false, status: 422, text: async () => '{"message":"Reference already exists"}' }),
  });
  await assert.rejects(
    publishVersion(github, { action: "tag", tag: "v0.18.0", version: "0.18.0", notes: "" }, HEAD),
    /git\/tags: HTTP 422/,
  );
});
