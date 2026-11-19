// When a held alert goes (`reasonToGo`), from its PR's row as the index holds it.
import assert from "node:assert/strict";
import { test } from "vitest";
import { ALERT_HOLD_MAX_MS, type HeldRow, reasonToGo } from "../../src/push-gate.ts";

const HEAD = "a".repeat(40);
const row = (fields: Partial<HeldRow> = {}): HeldRow => ({
  head: HEAD,
  diff_state: "pending",
  key_lines_ready: null,
  list: "review",
  ...fields,
});

test("a diff GitHub will not give counts as stored", () => {
  assert.equal(reasonToGo(row({ diff_state: "too_large" }), HEAD, false, 0), "ready");
});

test("with key lines on, an alert waits for them at its head too", () => {
  assert.equal(reasonToGo(row({ diff_state: "ready" }), HEAD, true, 2_000), null);
  assert.equal(
    reasonToGo(row({ diff_state: "ready", key_lines_ready: "b".repeat(40) }), HEAD, true, 3_000),
    null,
    "another head's key lines",
  );
  assert.equal(
    reasonToGo(row({ diff_state: "ready", key_lines_ready: HEAD }), HEAD, true, 6_000),
    "ready",
  );
});

test("past the bounded wait an alert goes anyway, timed out", () => {
  assert.equal(reasonToGo(row(), HEAD, false, ALERT_HOLD_MAX_MS - 1), null);
  assert.equal(reasonToGo(row(), HEAD, false, ALERT_HOLD_MAX_MS), "timed_out");
});
