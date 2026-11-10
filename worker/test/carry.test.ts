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
  sql.exec("CREATE TABLE pull_requests (id TEXT PRIMARY KEY, head TEXT)");
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
  assert.equal(writeCarriedIndexState(after, exported), 2);
  assert.equal(writeCarriedIndexState(after, exported), 2);
  assert.deepEqual(readCarriedIndexState(after).reviewedKeyLines, [
    { pr: PR, head: HEAD, line: "src/a.ts:RIGHT:3", at: 99 },
    { pr: PR, head: HEAD, line: "src/b.ts:LEFT:9", at: 11 },
  ]);
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
