import assert from "node:assert/strict";
import { test } from "node:test";
import { parseKeyLineMark } from "../src/boundary.ts";
import type { PrId, Sha } from "../src/ids.ts";
import {
  createReviewedKeyLinesTable, forgetReviewedKeyLinesOf, markKeyLine, MAX_REVIEWED_PER_HEAD, pruneReviewedKeyLines,
  REVIEWED_KEPT_MS, reviewedKeyLines,
} from "../src/reviewed-key-lines.ts";
import { memorySql } from "./memory-sql.ts";

const PR = "acme/api#7" as PrId;
const HEAD = "a".repeat(40) as Sha;
const NEXT = "b".repeat(40) as Sha;

function index() {
  const sql = memorySql();
  sql.exec("CREATE TABLE pull_requests (id TEXT PRIMARY KEY, head TEXT)");
  createReviewedKeyLinesTable(sql);
  createReviewedKeyLinesTable(sql);
  return sql;
}

test("a key line checked off on one device is checked off for the next, and unchecking it takes it back", () => {
  const sql = index();
  assert.deepEqual(reviewedKeyLines(sql, PR, HEAD), { head: HEAD, reviewed: [] });
  markKeyLine(sql, PR, HEAD, "src/b.ts:RIGHT:9", true, 1);
  assert.deepEqual(markKeyLine(sql, PR, HEAD, "src/a.ts:RIGHT:3", true, 2),
    { head: HEAD, reviewed: ["src/a.ts:RIGHT:3", "src/b.ts:RIGHT:9"] });
  assert.deepEqual(markKeyLine(sql, PR, HEAD, "src/a.ts:RIGHT:3", true, 3)?.reviewed.length, 2, "twice is once");
  assert.deepEqual(markKeyLine(sql, PR, HEAD, "src/b.ts:RIGHT:9", false, 4), { head: HEAD, reviewed: ["src/a.ts:RIGHT:3"] });
  assert.deepEqual(markKeyLine(sql, PR, HEAD, "src/b.ts:RIGHT:9", false, 5)?.reviewed, ["src/a.ts:RIGHT:3"]);
});

test("a new commit starts the review again, and another PR's ticks are its own", () => {
  const sql = index();
  markKeyLine(sql, PR, HEAD, "a:RIGHT:1", true, 1);
  assert.deepEqual(reviewedKeyLines(sql, PR, NEXT).reviewed, []);
  assert.deepEqual(reviewedKeyLines(sql, "acme/api#8" as PrId, HEAD).reviewed, []);
  assert.deepEqual(reviewedKeyLines(sql, PR, HEAD).reviewed, ["a:RIGHT:1"]);
});

test("a head keeps a bounded number of ticks, and a line already ticked still answers", () => {
  const sql = index();
  for (let line = 0; line < MAX_REVIEWED_PER_HEAD; line += 1) {
    markKeyLine(sql, PR, HEAD, `a:RIGHT:${line}`, true, 1);
  }
  assert.equal(markKeyLine(sql, PR, HEAD, "a:RIGHT:extra", true, 2), null);
  assert.equal(markKeyLine(sql, PR, HEAD, "a:RIGHT:0", true, 2)?.reviewed.length, MAX_REVIEWED_PER_HEAD);
  assert.equal(markKeyLine(sql, PR, NEXT, "a:RIGHT:extra", true, 2)?.reviewed.length, 1);
});

test("old ticks no held PR shows go; a held PR's ticks at its head stay however old", () => {
  const sql = index();
  sql.exec("INSERT INTO pull_requests (id, head) VALUES (?, ?)", "Acme/API#7", HEAD);
  markKeyLine(sql, PR, HEAD, "kept:RIGHT:1", true, 0);
  markKeyLine(sql, PR, NEXT, "older-head:RIGHT:1", true, 0);
  markKeyLine(sql, "acme/api#9" as PrId, HEAD, "off-list:RIGHT:1", true, 0);
  markKeyLine(sql, "acme/api#9" as PrId, NEXT, "recent:RIGHT:1", true, REVIEWED_KEPT_MS);
  assert.equal(pruneReviewedKeyLines(sql, REVIEWED_KEPT_MS + 1), 2);
  assert.deepEqual(reviewedKeyLines(sql, PR, HEAD).reviewed, ["kept:RIGHT:1"]);
  assert.deepEqual(reviewedKeyLines(sql, "acme/api#9" as PrId, NEXT).reviewed, ["recent:RIGHT:1"]);
});

test("losing a repo takes its ticks, whatever the case, and leaves a repo whose name starts the same", () => {
  const sql = index();
  markKeyLine(sql, PR, HEAD, "a:RIGHT:1", true, 1);
  markKeyLine(sql, "acme/api-docs#7" as PrId, HEAD, "a:RIGHT:1", true, 1);
  forgetReviewedKeyLinesOf(sql, "ACME/api");
  assert.deepEqual(reviewedKeyLines(sql, PR, HEAD).reviewed, []);
  assert.deepEqual(reviewedKeyLines(sql, "acme/api-docs#7" as PrId, HEAD).reviewed, ["a:RIGHT:1"]);
});

test("a mark names a head commit, a key line and whether it is reviewed", () => {
  assert.deepEqual(parseKeyLineMark({ head: HEAD, line: "a:RIGHT:1", reviewed: true }),
    { head: HEAD, line: "a:RIGHT:1", reviewed: true });
  assert.equal(parseKeyLineMark({ head: "main", line: "a:RIGHT:1", reviewed: true }), null);
  assert.equal(parseKeyLineMark({ head: HEAD, line: "", reviewed: true }), null);
  assert.equal(parseKeyLineMark({ head: HEAD, line: "a".repeat(1_101), reviewed: true }), null);
  assert.equal(parseKeyLineMark({ head: HEAD, line: "a:RIGHT:1", reviewed: "yes" }), null);
  assert.equal(parseKeyLineMark(null), null);
});
