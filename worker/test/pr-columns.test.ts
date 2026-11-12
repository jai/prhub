// The PR index's table catches up from any older shape, including one that has key_lines_ready but no queue columns.
import assert from "node:assert/strict";
import test from "node:test";
import { addMissingColumns } from "../src/pr-columns.ts";
import { memorySql } from "./memory-sql.ts";

const columnsOf = (sql: ReturnType<typeof memorySql>) =>
  sql.exec<{ name: string }>("PRAGMA table_info(pull_requests)").toArray().map(({ name }) => name).sort();

test("a table made with key_lines_ready alone gains the rest without adding it twice", () => {
  const sql = memorySql();
  sql.exec("CREATE TABLE pull_requests (id TEXT PRIMARY KEY, version TEXT NOT NULL DEFAULT '', status TEXT, key_lines_ready TEXT, detail_version TEXT)");
  addMissingColumns(sql);
  addMissingColumns(sql);
  assert.deepEqual(columnsOf(sql),
    ["detail_version", "id", "key_lines_queued", "key_lines_ready", "key_lines_tried_at", "people", "status", "ticket",
      "ticket_keys", "tickets", "version"]);
});

test("the first table shape gains every column", () => {
  const sql = memorySql();
  sql.exec("CREATE TABLE pull_requests (id TEXT PRIMARY KEY)");
  addMissingColumns(sql);
  assert.equal(columnsOf(sql).length, 11);
});
