import assert from "node:assert/strict";
import { test } from "node:test";
import { createAskTables, queueAsk } from "../src/ask-queue.ts";
import {
  readCarriedAskState, readCarriedIndexState, writeCarriedAskState, writeCarriedIndexState,
} from "../src/carry.ts";
import type { PrId, Sha } from "../src/ids.ts";
import { createReviewedKeyLinesTable, markKeyLine } from "../src/reviewed-key-lines.ts";
import { memorySql } from "./memory-sql.ts";

const PR = "acme/api#7" as PrId;
const HEAD = "a".repeat(40) as Sha;

function index() {
  const sql = memorySql();
  sql.exec(`CREATE TABLE pull_requests (id TEXT PRIMARY KEY, repo TEXT, number INTEGER, head TEXT, list TEXT,
    revision TEXT, diff_state TEXT, diff_tried_at INTEGER)`);
  createReviewedKeyLinesTable(sql);
  createAskTables(sql);
  return sql;
}

test("the ticks on one Worker's index are the next one's, and carrying them twice adds nothing", () => {
  const before = index();
  markKeyLine(before, PR, HEAD, "src/a.ts:RIGHT:3", true, 10);
  markKeyLine(before, PR, HEAD, "src/b.ts:LEFT:9", true, 11);
  const after = index();
  markKeyLine(after, PR, HEAD, "src/a.ts:RIGHT:3", true, 99);

  const exported = readCarriedIndexState(before);
  assert.deepEqual(writeCarriedIndexState(after, exported), { reviewedKeyLines: 2, reviewedPullRequests: 0 });
  assert.deepEqual(writeCarriedIndexState(after, exported), { reviewedKeyLines: 2, reviewedPullRequests: 0 });
  assert.deepEqual(readCarriedIndexState(after).reviewedKeyLines, [
    { pr: PR, head: HEAD, line: "src/a.ts:RIGHT:3", at: 99 },
    { pr: PR, head: HEAD, line: "src/b.ts:LEFT:9", at: 11 },
  ]);
});

test("a PR held on Recently Reviewed comes across held there, and only those", () => {
  const before = index();
  before.exec("INSERT INTO pull_requests (id, repo, number, list) VALUES (?, ?, ?, ?)", "acme/api#7", "acme/api", 7, "reviewed");
  before.exec("INSERT INTO pull_requests (id, repo, number, list) VALUES (?, ?, ?, ?)", "acme/api#8", "acme/api", 8, "review");
  const after = index();

  const exported = readCarriedIndexState(before);
  assert.deepEqual(exported.reviewedPullRequests, [{ id: "acme/api#7", repo: "acme/api", number: 7 }]);
  assert.deepEqual(writeCarriedIndexState(after, exported), { reviewedKeyLines: 0, reviewedPullRequests: 1 });
  assert.deepEqual(readCarriedIndexState(after).reviewedPullRequests, exported.reviewedPullRequests);
  assert.deepEqual(after.exec("SELECT diff_state FROM pull_requests").toArray(), [{ diff_state: "pending" }],
    "its diff is fetched, so the list never names a PR with no diff state");
});

test("a row carried with no diff state is given one when the import runs again", () => {
  const after = index();
  after.exec("INSERT INTO pull_requests (id, repo, number, list) VALUES (?, ?, ?, ?)", "acme/api#7", "acme/api", 7, "reviewed");
  writeCarriedIndexState(after, { reviewedKeyLines: [], reviewedPullRequests: [] });
  assert.deepEqual(after.exec("SELECT diff_state, diff_tried_at FROM pull_requests").toArray(),
    [{ diff_state: "pending", diff_tried_at: 0 }]);
});

test("Ask's queue and chats move with their ids, failures included", () => {
  const before = index();
  const question = { id: "q1", repo: "acme/api", number: 7, at: 5, error: null };
  queueAsk(before, question as Parameters<typeof queueAsk>[1]);
  before.exec("INSERT INTO ask_chats (pr, chat, at) VALUES (?, ?, ?)", "acme/api#7", "{}", 6);
  before.exec("UPDATE asks SET error = ? WHERE id = ?", "The question didn't reach the AI. Try again.", "q1");
  const after = index();

  const exported = readCarriedAskState(before);
  assert.deepEqual(writeCarriedAskState(after, exported), { asks: 1, askChats: 1 });
  assert.deepEqual(readCarriedAskState(after), exported);
});
