import assert from "node:assert/strict";
import { test } from "vitest";
import { prId, repoOf } from "../../src/ids.ts";
import { sweepClosedPullRequests } from "../../src/retention.ts";
import { memoryR2 } from "../support/memory-r2.ts";

const NOW = Date.parse("2026-11-07T00:00:00Z");

test("the sweep deletes a closed PR's objects once the newest is past retention, and keeps open PRs'", async () => {
  const day = 86_400_000;
  // Two keys a page, so the sweep pages through the list.
  const bucket = memoryR2(
    {
      "users/1/acme/api/7/r1.diff": { body: "", uploaded: new Date(NOW - 40 * day) },
      "users/1/acme/api/7/detail/v1.json": { body: "", uploaded: new Date(NOW - 40 * day) },
      "users/1/ai/acme/api/7/head/rewrite.json": { body: "", uploaded: new Date(NOW - 35 * day) },
      [`users/1/acme/api/7/${"a".repeat(40)}/file/${"0".repeat(64)}`]: {
        body: "",
        uploaded: new Date(NOW - 36 * day),
      },
      "users/1/acme/api/8/r1.diff": { body: "", uploaded: new Date(NOW - 40 * day) },
      "users/1/acme/api/8/detail/v2.json": { body: "", uploaded: new Date(NOW - 2 * day) },
      "users/1/acme/api/9/r1.diff": { body: "", uploaded: new Date(NOW - 90 * day) },
      "users/1/repos/index.json": { body: "", uploaded: new Date(NOW - 90 * day) },
    },
    { pageSize: 2 },
  );
  const deleted = await sweepClosedPullRequests(
    bucket.binding,
    "users/1/",
    (id) => id === prId(repoOf("acme/api"), 9),
    NOW - 30 * day,
  );
  assert.equal(deleted, 4);
  assert.deepEqual([...bucket.objects.keys()].sort(), [
    "users/1/acme/api/8/detail/v2.json",
    "users/1/acme/api/8/r1.diff",
    "users/1/acme/api/9/r1.diff",
    "users/1/repos/index.json",
  ]);
  assert.equal(
    await sweepClosedPullRequests(
      bucket.binding,
      "users/1/",
      (id) => id === prId(repoOf("acme/api"), 9),
      NOW - 30 * day,
    ),
    0,
    "a second run finds nothing left",
  );
});
