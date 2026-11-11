// The push gate on real SQLite: an alert goes once its PR's files are stored at its head, or after the bounded wait.
import assert from "node:assert/strict";
import test from "node:test";
import type { PrAlert } from "../src/alerts.ts";
import { alertMessage } from "../src/alerts.ts";
import type { RepoFullName } from "../src/ids.ts";
import { ALERT_HOLD_MAX_MS, createHeldAlertsTable, type HeldRow, holdAlert, releaseAlerts } from "../src/push-gate.ts";
import { memorySql } from "./memory-sql.ts";

const HEAD = "a".repeat(40);
const NOW = Date.parse("2026-11-08T07:00:00Z");
const alert: PrAlert = { kind: "review_requested", repo: "acme/api" as RepoFullName, number: 7, head: HEAD, title: "Add retries" };

function index(row: Partial<HeldRow> | null) {
  const sql = memorySql();
  sql.exec("CREATE TABLE pull_requests (id TEXT PRIMARY KEY, head TEXT, diff_state TEXT)");
  createHeldAlertsTable(sql);
  if (row) {
    sql.exec("INSERT INTO pull_requests (id, head, diff_state) VALUES (?, ?, ?)",
      "acme/api#7", row.head ?? HEAD, row.diff_state ?? "pending");
  }
  holdAlert(sql, "review_requested:acme/api#7@a", alert, NOW);
  const setRow = (fields: Partial<HeldRow>) => {
    for (const [column, value] of Object.entries(fields)) {
      sql.exec(`UPDATE pull_requests SET ${column} = ? WHERE id = ?`, value, "acme/api#7");
    }
  };
  return { sql, setRow };
}

test("an alert waits for its diff, then goes once with how long it was held", () => {
  const { sql, setRow } = index({ diff_state: "pending" });
  const waiting = releaseAlerts(sql, NOW + 400);
  assert.deepEqual(waiting.release, []);
  assert.equal(waiting.nextAt, NOW + ALERT_HOLD_MAX_MS, "an alarm at the deadline");
  setRow({ diff_state: "ready" });
  const sent = releaseAlerts(sql, NOW + 900);
  assert.deepEqual(sent.release, [{ alert, heldMs: 900, reason: "ready" }]);
  assert.equal(sent.nextAt, null);
  assert.deepEqual(releaseAlerts(sql, NOW + 1_000).release, [], "sent once");
});

test("a diff GitHub will not give counts as stored", () => {
  const { sql } = index({ diff_state: "too_large" });
  assert.equal(releaseAlerts(sql, NOW).release[0]?.reason, "ready");
});

test("past the bounded wait an alert goes anyway, timed out", () => {
  const { sql } = index({ diff_state: "pending" });
  assert.deepEqual(releaseAlerts(sql, NOW + ALERT_HOLD_MAX_MS - 1).release, []);
  assert.deepEqual(releaseAlerts(sql, NOW + ALERT_HOLD_MAX_MS).release,
    [{ alert, heldMs: ALERT_HOLD_MAX_MS, reason: "timed_out" }]);
});

test("a head that moved on releases the alert at once; a PR off every list drops it", () => {
  const moved = index({ head: "c".repeat(40), diff_state: "pending" });
  assert.equal(releaseAlerts(moved.sql, NOW + 10).release[0]?.reason, "moved");
  const gone = index(null);
  const decision = releaseAlerts(gone.sql, NOW + 10);
  assert.deepEqual(decision.release, []);
  assert.deepEqual(decision.dropped, [alert]);
  assert.equal(releaseAlerts(gone.sql, NOW + 20).dropped.length, 0, "dropped once");
});

test("holding the same alert twice keeps the first wait", () => {
  const { sql, setRow } = index({ diff_state: "pending" });
  holdAlert(sql, "review_requested:acme/api#7@a", alert, NOW + 5_000);
  setRow({ diff_state: "ready" });
  assert.equal(releaseAlerts(sql, NOW + 6_000).release[0]?.heldMs, 6_000);
});

test("an alert carries its row for the phone's prefetch, and leaves it out when it would not fit", () => {
  const row = { repo: "acme/api", number: 7, title: "Add retries", head: HEAD, revision: `${HEAD}-main`, diff: "ready",
    detail: "2026-11-08T07:00:00Z.SUCCESS.0123456789abcdef", status: null, keyLines: null };
  const message = alertMessage(alert, row);
  assert.deepEqual(message.payload.row, row);
  assert.equal((message.payload.aps as Record<string, unknown>)["mutable-content"], 1);
  const huge = alertMessage(alert, { ...row, title: "x".repeat(5_000) });
  assert.equal(huge.payload.row, undefined);
  assert.ok(new TextEncoder().encode(JSON.stringify(huge.payload)).length <= 4096);
});
