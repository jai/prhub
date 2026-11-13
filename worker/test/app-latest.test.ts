import assert from "node:assert/strict";
import test from "node:test";
import { APP_LATEST_URL, appLatest, forgetAppLatest, parseAppLatest } from "../src/app-latest.ts";

const published = { internal: { version: "1.0", build: "212" }, public: { version: "1.0", build: "198" } };

function answering(...answers: (object | Error)[]) {
  const urls: string[] = [];
  const fetchImpl = (async (input: RequestInfo | URL) => {
    urls.push(String(input));
    const answer = answers.shift() ?? new Error("no answer left");
    if (answer instanceof Error) {
      throw answer;
    }
    return Response.json(answer);
  }) as typeof fetch;
  return { urls, fetchImpl };
}

test("the published file's groups are kept only when well formed", () => {
  assert.deepEqual(parseAppLatest(published), published);
  assert.deepEqual(parseAppLatest({ public: { version: "1.2.3", build: "7" }, internal: { version: "1", build: 8 } }),
    { public: { version: "1.2.3", build: "7" } });
  assert.equal(parseAppLatest({ internal: { version: "beta", build: "1" } }), undefined);
  assert.equal(parseAppLatest([]), undefined);
  assert.equal(parseAppLatest(null), undefined);
});

test("PRHub's own file unless APP_LATEST_URL says another, and none when it says off", async () => {
  forgetAppLatest();
  const own = answering(published);
  assert.deepEqual(await appLatest({}, own.fetchImpl, 0), published);
  assert.deepEqual(own.urls, [APP_LATEST_URL]);

  forgetAppLatest();
  const fork = answering(published);
  await appLatest({ APP_LATEST_URL: "https://example.com/latest.json" }, fork.fetchImpl, 0);
  assert.deepEqual(fork.urls, ["https://example.com/latest.json"]);

  forgetAppLatest();
  const off = answering(published);
  assert.equal(await appLatest({ APP_LATEST_URL: "off" }, off.fetchImpl, 0), undefined);
  assert.deepEqual(off.urls, []);
});

test("kept 10 minutes; a failed read answers the last one and is tried again a minute later", async () => {
  forgetAppLatest();
  const newer = { ...published, internal: { version: "1.0", build: "213" } };
  const reads = answering(published, new Error("down"), newer);
  assert.deepEqual(await appLatest({}, reads.fetchImpl, 0), published);
  assert.deepEqual(await appLatest({}, reads.fetchImpl, 9 * 60_000), published);
  assert.equal(reads.urls.length, 1);
  assert.deepEqual(await appLatest({}, reads.fetchImpl, 10 * 60_000), published, "the read failed");
  assert.deepEqual(await appLatest({}, reads.fetchImpl, 10 * 60_000 + 30_000), published, "not asked again yet");
  assert.equal(reads.urls.length, 2);
  assert.deepEqual(await appLatest({}, reads.fetchImpl, 11 * 60_000), newer);
  assert.equal(reads.urls.length, 3);
});

test("nothing read yet and the read fails: no app_latest", async () => {
  forgetAppLatest();
  assert.equal(await appLatest({}, answering(new Error("down")).fetchImpl, 0), undefined);
});
