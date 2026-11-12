import assert from "node:assert/strict";
import { test } from "node:test";
import { type FeatureKitEnv, parseApps, roleOf, serveFeatureKit, takeIssue } from "../src/featurekit.ts";
import { r2Store } from "../src/feedback.ts";

/** R2 as the FeedbackKit Worker uses it: versions, a put over a moved version refused, prefix listing. */
function memoryBucket(): R2Bucket {
  const objects = new Map<string, { body: string; etag: string }>();
  let version = 0;
  const object = (key: string) => {
    const found = objects.get(key)!;
    return { key, etag: found.etag, json: async () => JSON.parse(found.body), body: found.body, httpMetadata: {} };
  };
  return {
    async get(key: string) {
      return objects.has(key) ? object(key) : null;
    },
    async put(key: string, value: unknown, options?: { onlyIf?: { etagMatches?: string } | Headers }) {
      const onlyIf = options?.onlyIf;
      if (onlyIf instanceof Headers ? onlyIf.get("If-None-Match") === "*" && objects.has(key)
        : onlyIf?.etagMatches && objects.get(key)?.etag !== onlyIf.etagMatches) {
        return null;
      }
      objects.set(key, { body: typeof value === "string" ? value : "bytes", etag: `v${++version}` });
      return object(key);
    },
    async list({ prefix }: { prefix: string }) {
      return { objects: [...objects.keys()].filter((key) => key.startsWith(prefix)).map((key) => ({ key })), truncated: false };
    },
    async delete(key: string) {
      objects.delete(key);
    },
  } as unknown as R2Bucket;
}

const APPS = JSON.stringify({
  prhub: { repo: "acme/app", owners: ["Octocat"], builders: ["hubot"], issues: true },
  pager: { repo: "acme/pager", owners: ["octocat"] },
});

function env(): FeatureKitEnv {
  return { FEEDBACK: memoryBucket(), APPS, CALLER_TOKEN: "caller", RUNNER_TOKEN: "runner" };
}

function fromApp(e: FeatureKitEnv, path: string, login: string, body?: unknown, app = "prhub") {
  return serveFeatureKit(new Request(`https://kit.example${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { Authorization: "Bearer caller", "X-FeedbackKit-App": app, "X-FeedbackKit-Login": login },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), e);
}

function fromRunner(e: FeatureKitEnv, kind: string, body: unknown) {
  return serveFeatureKit(new Request(`https://kit.example/runner/${kind}`, {
    method: "POST", headers: { Authorization: "Bearer runner" }, body: JSON.stringify(body),
  }), e);
}

test("each app says who builds: owners ship, builders open a PR, everyone else files an issue", () => {
  const apps = parseApps(APPS);
  assert.equal(roleOf(apps.prhub, "octocat"), "owner");
  assert.equal(roleOf(apps.prhub, "HUBOT"), "builder");
  assert.equal(roleOf(apps.prhub, "someone"), "issue");
  assert.equal(roleOf(apps.pager, "someone"), null);
});

test("an owner's and a builder's feedback each wait for the runner as their own chats, with the app's repo", async () => {
  const e = env();
  const mine = await (await fromApp(e, "/feedback", "octocat", { text: "Bigger diff font", client_ref: "a" })).json();
  const theirs = await (await fromApp(e, "/feedback", "hubot", { text: "Dark mode" })).json();
  const again = await (await fromApp(e, "/feedback", "octocat", { text: "Bigger diff font", client_ref: "a" })).json();
  assert.equal(again.id, mine.id);
  const list = await (await fromApp(e, "/feedback", "octocat")).json();
  assert.deepEqual(list.threads.map((thread: { id: string }) => thread.id), [mine.id]);
  const { work } = await (await fromRunner(e, "poll", { orca: true })).json();
  assert.deepEqual(work.map((item: Record<string, string>) => [item.chat, item.login, item.repo, item.role]), [
    [mine.id, "octocat", "acme/app", "owner"], [theirs.id, "hubot", "acme/app", "builder"],
  ]);
  const claim = await (await fromRunner(e, "claim", { app: "prhub", login: "hubot", chat: theirs.id, message: work[1].message })).json();
  assert.equal(claim.text, "Dark mode");
  assert.equal(claim.role, "builder");
  const wrong = await fromRunner(e, "claim", { app: "prhub", login: "octocat", chat: theirs.id, message: work[1].message });
  assert.equal(wrong.status, 404);
});

test("nobody reaches feedback without the app Worker's or the runner's token, and an app with no issues refuses others", async () => {
  const e = env();
  const bare = await serveFeatureKit(new Request("https://kit.example/feedback", { headers: { "X-FeedbackKit-App": "prhub" } }), e);
  assert.equal(bare.status, 401);
  const runner = await serveFeatureKit(new Request("https://kit.example/runner/poll", { method: "POST" }), e);
  assert.equal(runner.status, 401);
  assert.equal((await fromApp(e, "/feedback", "someone", undefined, "pager")).status, 403);
  assert.equal((await fromApp(e, "/feedback", "someone", { text: "hi" })).status, 503);
});

test("sends at once each take their own place under the daily issue cap", async () => {
  const store = r2Store(memoryBucket());
  const now = Date.parse("2026-11-12T10:00:00Z");
  const taken = await Promise.all(Array.from({ length: 14 }, () => takeIssue(store, now)));
  assert.equal(taken.filter(Boolean).length, 10);
  assert.equal(await takeIssue(store, now + 86_400_001), true, "a day later there is room again");
});
