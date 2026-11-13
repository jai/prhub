import assert from "node:assert/strict";
import test from "node:test";
import { latestFile, publish, recentBuilds } from "./app-latest.mjs";

test("App Store Connect's builds, with their version and where testers can install them", async () => {
  const document = {
    data: [
      { attributes: { version: "214" }, relationships: {
        preReleaseVersion: { data: { type: "preReleaseVersions", id: "v1" } },
        buildBetaDetail: { data: { type: "buildBetaDetails", id: "d214" } } } },
      { attributes: { version: "198" }, relationships: {
        preReleaseVersion: { data: { type: "preReleaseVersions", id: "v1" } },
        buildBetaDetail: { data: { type: "buildBetaDetails", id: "d198" } } } },
    ],
    included: [
      { type: "preReleaseVersions", id: "v1", attributes: { version: "1.0" } },
      { type: "buildBetaDetails", id: "d214",
        attributes: { internalBuildState: "IN_BETA_TESTING", externalBuildState: "READY_FOR_BETA_SUBMISSION" } },
      { type: "buildBetaDetails", id: "d198",
        attributes: { internalBuildState: "IN_BETA_TESTING", externalBuildState: "IN_BETA_TESTING" } },
    ],
  };
  const paths = [];
  const builds = await recentBuilds(async (method, path) => {
    paths.push(`${method} ${path}`);
    return document;
  });
  assert.match(paths[0], /^GET builds\?filter\[app\]=6831601628&filter\[processingState\]=VALID&filter\[expired\]=false/);
  assert.deepEqual(builds, [
    { version: "1.0", build: "214", internal: true, external: false },
    { version: "1.0", build: "198", internal: true, external: true },
  ]);
});

test("each group's newest build by number, not by upload", () => {
  const text = latestFile([
    { version: "1.0", build: "99", internal: true, external: true },
    { version: "1.1", build: "214", internal: true, external: false },
    { version: "1.0", build: "198", internal: true, external: true },
    { version: "1.1", build: "220", internal: false, external: false },
  ]);
  assert.deepEqual(JSON.parse(text),
    { internal: { version: "1.1", build: "214" }, public: { version: "1.0", build: "198" } });
  assert.equal(latestFile([]), "{}\n");
});

/** A fake GitHub that keeps the branch's file. */
function fakeGitHub(file) {
  const calls = [];
  const github = async (method, path, body) => {
    calls.push(`${method} ${path.split("?")[0]}`);
    if (method === "GET" && path.startsWith("contents/")) {
      return file === undefined ? null : { sha: "s1", content: Buffer.from(file).toString("base64") };
    }
    if (method === "GET" && path.startsWith("git/ref/")) return null;
    if (method === "PUT") {
      assert.equal(body.branch, "ci/app-latest");
      assert.equal(body.sha, "s1");
      file = Buffer.from(body.content, "base64").toString("utf8");
      return {};
    }
    if (path === "git/trees") return { sha: "t1" };
    if (path === "git/commits") {
      assert.deepEqual(body.parents, []);
      return { sha: "c1" };
    }
    if (path === "git/refs") {
      assert.deepEqual(body, { ref: "refs/heads/ci/app-latest", sha: "c1" });
      return {};
    }
    throw new Error(`unexpected ${method} ${path}`);
  };
  return { github, calls, file: () => file };
}

test("written only when it changed, and the branch made when it is missing", async () => {
  const same = fakeGitHub("{}\n");
  assert.equal(await publish(same.github, "{}\n"), "unchanged");
  assert.deepEqual(same.calls, ["GET contents/app-latest.json"]);

  const changed = fakeGitHub("{}\n");
  assert.equal(await publish(changed.github, '{"public":{}}\n'), "updated");
  assert.equal(changed.file(), '{"public":{}}\n');

  const missing = fakeGitHub(undefined);
  assert.equal(await publish(missing.github, "{}\n"), "created");
  assert.deepEqual(missing.calls,
    ["GET contents/app-latest.json", "POST git/trees", "POST git/commits", "GET git/ref/heads/ci/app-latest", "POST git/refs"]);
});
