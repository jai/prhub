import type { LimitSql } from "./limit-counter.ts";

/** The columns `pull_requests` gained after it was first made, each added alone, so any older table catches up. */
const ADDED_COLUMNS: [name: string, type: string][] = [
  ["version", "TEXT NOT NULL DEFAULT ''"],
  ["status", "TEXT"],
  ["key_lines_queued", "TEXT"],
  ["key_lines_ready", "TEXT"],
  ["key_lines_tried_at", "INTEGER"],
  ["detail_version", "TEXT"],
  ["ticket", "TEXT"],
  ["ticket_keys", "TEXT"],
  ["tickets", "TEXT"],
];

export function addMissingColumns(sql: LimitSql): void {
  const have = new Set(sql.exec<{ name: string }>("PRAGMA table_info(pull_requests)").toArray().map(({ name }) => name));
  for (const [name, type] of ADDED_COLUMNS) {
    if (!have.has(name)) {
      sql.exec(`ALTER TABLE pull_requests ADD COLUMN ${name} ${type}`);
    }
  }
}
