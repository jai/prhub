// The PR index's marks on real SQLite (`marks.ts`): a burst of deliveries for one PR or head is one read per window.
import assert from "node:assert/strict";
import { test } from "node:test";
import { prId, type RepoFullName } from "../src/ids.ts";
import {
  BUSY_WINDOW_MS, CHECKS_WINDOW_MS, createMarkTables, dueMarks, finishRead, mark, nextDueAt, PR_EVENT_WINDOW_MS,
  type Scope, throttledDue,
} from "../src/marks.ts";
import { memorySql } from "./memory-sql.ts";

const repo = "acme/app" as RepoFullName;
const pr = { id: prId(repo, 7), repo, number: 7 };
const T0 = Date.parse("2026-11-12T15:45:00Z");

function index() {
  const sql = memorySql();
  createMarkTables(sql);
  /** A delivery at `at`, marked as the index marks one. */
  const deliver = (scope: Scope, at: number) => mark(sql, pr, scope, throttledDue(sql, pr.id, scope, at));
  /** An alarm at `at`: the reads due then, each finished. */
  const alarm = (scope: Scope, at: number) => {
    const due = dueMarks(sql, scope, at, 25);
    for (const one of due) {
      finishRead(sql, scope, one, at);
    }
    return due.length;
  };
  return { sql, deliver, alarm };
}

test("a CI run's check events for one head are one checks read per window, the first a moment after quiet", () => {
  const { sql, deliver, alarm } = index();
  deliver("checks", T0);
  assert.equal(nextDueAt(sql), T0 + BUSY_WINDOW_MS, "the first event after quiet is read in seconds");
  let reads = 0;
  // 120 check suites and statuses over ten minutes, one every five seconds, with an alarm at every due time.
  for (let at = T0; at < T0 + 600_000; at += 5_000) {
    deliver("checks", at);
    const due = nextDueAt(sql);
    if (due !== null && due <= at + 5_000) {
      reads += alarm("checks", due);
    }
  }
  assert.ok(reads <= 600_000 / CHECKS_WINDOW_MS + 1, `${reads} reads for 120 events`);
  assert.ok(reads >= 600_000 / CHECKS_WINDOW_MS - 1, "and never starved: one a window while they keep coming");
});

test("more deliveries never push a waiting read back", () => {
  const { sql, deliver, alarm } = index();
  deliver("full", T0);
  alarm("full", T0 + BUSY_WINDOW_MS);
  deliver("full", T0 + 4_000);
  assert.equal(nextDueAt(sql), T0 + BUSY_WINDOW_MS + PR_EVENT_WINDOW_MS);
  deliver("full", T0 + 10_000);
  deliver("full", T0 + 17_000);
  assert.equal(nextDueAt(sql), T0 + BUSY_WINDOW_MS + PR_EVENT_WINDOW_MS);
});

test("a full read covers the checks marked before it, and a checks mark waits behind it", () => {
  const { sql, deliver, alarm } = index();
  deliver("full", T0);
  deliver("checks", T0);
  assert.equal(dueMarks(sql, "checks", T0 + BUSY_WINDOW_MS, 25).length, 0, "the full read will see the checks too");
  assert.equal(alarm("full", T0 + BUSY_WINDOW_MS), 1);
  assert.equal(nextDueAt(sql), null, "nothing left: the checks were read with it");
  deliver("checks", T0 + 5_000);
  assert.equal(nextDueAt(sql), T0 + BUSY_WINDOW_MS + CHECKS_WINDOW_MS, "a full read starts the checks window too");
});

test("a delivery during a read survives it", () => {
  const { sql, deliver } = index();
  deliver("checks", T0);
  const [inFlight] = dueMarks(sql, "checks", T0 + BUSY_WINDOW_MS, 25);
  deliver("checks", T0 + 3_500);
  finishRead(sql, "checks", inFlight!, T0 + 4_000);
  assert.equal(nextDueAt(sql), T0 + 4_000 + CHECKS_WINDOW_MS);
});

test("a dirty table from before due_at gains it, its marks due at once", () => {
  const sql = memorySql();
  sql.exec("CREATE TABLE dirty (id TEXT PRIMARY KEY, repo TEXT, number INTEGER, generation INTEGER)");
  sql.exec("INSERT INTO dirty (id, repo, number, generation) VALUES (?, ?, ?, 1)", pr.id, repo, 7);
  createMarkTables(sql);
  assert.equal(nextDueAt(sql), 0);
  assert.equal(dueMarks(sql, "full", T0, 5).length, 1);
});
