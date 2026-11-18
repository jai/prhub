import assert from "node:assert/strict";
import { test } from "node:test";
import type { PrAlert } from "../../src/alerts.ts";
import { alertMessage } from "../../src/alerts.ts";
import type { RepoFullName } from "../../src/ids.ts";

const HEAD = "a".repeat(40);
const alert: PrAlert = {
  kind: "review_requested",
  repo: "acme/api" as RepoFullName,
  number: 7,
  head: HEAD,
  title: "Add retries",
};

test("an alert carries its row for the phone's prefetch, and leaves it out when it would not fit", () => {
  const row = {
    repo: "acme/api",
    number: 7,
    title: "Add retries",
    head: HEAD,
    revision: `${HEAD}-main`,
    diff: "ready",
    detail: "2026-11-08T07:00:00Z.SUCCESS.0123456789abcdef",
    status: null,
    keyLines: null,
  };
  const message = alertMessage(alert, row);
  assert.deepEqual(message.payload.row, row);
  assert.equal((message.payload.aps as Record<string, unknown>)["mutable-content"], 1);
  const huge = alertMessage(alert, { ...row, title: "x".repeat(5_000) });
  assert.equal(huge.payload.row, undefined);
  assert.ok(new TextEncoder().encode(JSON.stringify(huge.payload)).length <= 4096);
});
