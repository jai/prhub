import assert from "node:assert/strict";
import { test, vi } from "vitest";
import { AskChanges } from "../../src/ask-changes.ts";

const PR = "acme/api#7";

test("a change ends every wait on its own PR, and no other's", async () => {
  vi.useFakeTimers();
  const changes = new AskChanges(100);
  const ended: string[] = [];
  const { version } = changes.now(PR);
  const all = [
    changes.wait(PR, version, 10_000).then(() => ended.push("first")),
    changes.wait(PR, version, 10_000).then(() => ended.push("second")),
    changes.wait("acme/web#1", version, 10_000).then(() => ended.push("other")),
  ];
  changes.changed(PR);
  await vi.advanceTimersByTimeAsync(0);
  assert.deepEqual(ended, ["first", "second"]);
  await vi.advanceTimersByTimeAsync(10_000);
  await Promise.all(all);
  assert.deepEqual(ended, ["first", "second", "other"]);
  vi.useRealTimers();
});

test("a change between the read and the wait ends the wait at once", async () => {
  const changes = new AskChanges(100);
  const { version } = changes.now(PR);
  changes.doing(PR, "Reading retry.ts");
  await changes.wait(PR, version, 60_000);
  assert.equal(changes.now(PR).activity, "Reading retry.ts");
  changes.doing(PR, null);
  assert.equal(changes.now(PR).activity, null);
});

test("a version from the object before this one waits for nothing", async () => {
  const before = new AskChanges(100);
  before.changed(PR);
  await new AskChanges(5_000).wait(PR, before.now(PR).version, 60_000);
});
