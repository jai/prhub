import assert from "node:assert/strict";
import { test } from "vitest";
import { prId, repoOf } from "../../src/ids.ts";
import { sweepClosedPullRequests } from "../../src/retention.ts";

const NOW = Date.parse("2026-11-07T00:00:00Z");

test("the sweep deletes a closed PR's objects once the newest is past retention, and keeps open PRs'", async () => {
  const day = 86_400_000;
  const objects = new Map<string, Date>([
    ["users/1/acme/api/7/r1.diff", new Date(NOW - 40 * day)],
    ["users/1/acme/api/7/detail/v1.json", new Date(NOW - 40 * day)],
    ["users/1/ai/acme/api/7/head/rewrite.json", new Date(NOW - 35 * day)],
    ["users/1/acme/api/8/r1.diff", new Date(NOW - 40 * day)],
    ["users/1/acme/api/8/detail/v2.json", new Date(NOW - 2 * day)],
    ["users/1/acme/api/9/r1.diff", new Date(NOW - 90 * day)],
    ["users/1/repos/index.json", new Date(NOW - 90 * day)],
  ]);
  const bucket = {
    list: async ({ cursor }: { cursor?: string }) => {
      const keys = [...objects.keys()].sort();
      const start = cursor ? Number(cursor) : 0;
      const page = keys.slice(start, start + 2);
      const truncated = start + 2 < keys.length;
      return {
        objects: page.map((key) => ({ key, uploaded: objects.get(key) as Date })),
        truncated,
        cursor: truncated ? String(start + 2) : undefined,
      };
    },
    delete: async (keys: string | string[]) => {
      for (const key of [keys].flat()) {
        objects.delete(key);
      }
    },
  } as unknown as Pick<R2Bucket, "list" | "delete">;
  const deleted = await sweepClosedPullRequests(
    bucket,
    "users/1/",
    (id) => id === prId(repoOf("acme/api"), 9),
    NOW - 30 * day,
  );
  assert.equal(deleted, 3);
  assert.deepEqual([...objects.keys()].sort(), [
    "users/1/acme/api/8/detail/v2.json",
    "users/1/acme/api/8/r1.diff",
    "users/1/acme/api/9/r1.diff",
    "users/1/repos/index.json",
  ]);
  assert.equal(
    await sweepClosedPullRequests(
      bucket,
      "users/1/",
      (id) => id === prId(repoOf("acme/api"), 9),
      NOW - 30 * day,
    ),
    0,
    "a second run finds nothing left",
  );
});
