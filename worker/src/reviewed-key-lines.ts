// Key lines the reader has checked off (docs/api.md, "Reviewed key lines"): kept in the index by PR and head, so every
// device of theirs shows the same ticks, and a new commit starts the review again.
import type { PrId, Sha } from "./ids.ts";
import type { LimitSql } from "./limit-counter.ts";

/** More ticks than a key lines list holds, at one head: the most one PR keeps. */
export const MAX_REVIEWED_PER_HEAD = 500;
/** A key line's id, `path:side:line`: a path GitHub allows, and the rest. */
export const MAX_KEY_LINE_ID = 1_100;
/** Ticks at a head no held PR has: kept this long after the last one, for a PR opened from a link. */
export const REVIEWED_KEPT_MS = 30 * 86_400_000;

/** What `GET` and `POST /prs/{owner}/{repo}/{n}/key-lines-reviewed` answer: the key lines checked off at `head`. */
export interface ReviewedKeyLines {
  head: Sha;
  /** Key line ids as the app names them, `path:side:line`, sorted. */
  reviewed: string[];
}

export function createReviewedKeyLinesTable(sql: LimitSql): void {
  sql.exec(`CREATE TABLE IF NOT EXISTS reviewed_key_lines (pr TEXT, head TEXT, line TEXT, at INTEGER,
    PRIMARY KEY (pr, head, line))`);
}

export function reviewedKeyLines(sql: LimitSql, pr: PrId, head: Sha): ReviewedKeyLines {
  const rows = sql.exec<{ line: string }>(
    "SELECT line FROM reviewed_key_lines WHERE pr = ? AND head = ? ORDER BY line", pr, head).toArray();
  return { head, reviewed: rows.map((row) => row.line) };
}

/** Checks a key line off at `head`, or back on. Null when the head already holds as many as it may. */
export function markKeyLine(
  sql: LimitSql, pr: PrId, head: Sha, line: string, reviewed: boolean, now: number,
): ReviewedKeyLines | null {
  if (!reviewed) {
    sql.exec("DELETE FROM reviewed_key_lines WHERE pr = ? AND head = ? AND line = ?", pr, head, line);
    return reviewedKeyLines(sql, pr, head);
  }
  const held = reviewedKeyLines(sql, pr, head).reviewed;
  if (!held.includes(line) && held.length >= MAX_REVIEWED_PER_HEAD) {
    return null;
  }
  sql.exec(`INSERT INTO reviewed_key_lines (pr, head, line, at) VALUES (?, ?, ?, ?)
    ON CONFLICT (pr, head, line) DO UPDATE SET at = excluded.at`, pr, head, line, now);
  return reviewedKeyLines(sql, pr, head);
}

/** The person lost this repo: its ticks, which name its files, go now. */
export function forgetReviewedKeyLinesOf(sql: LimitSql, repo: string): void {
  sql.exec("DELETE FROM reviewed_key_lines WHERE lower(substr(pr, 1, ?)) = lower(?)", repo.length + 1, `${repo}#`);
}

/**
 * Ticks no held PR shows any more (an older head, or a PR off the list) go once they are `REVIEWED_KEPT_MS` old. A held
 * PR's ticks at its head stay however old they are. Answers how many went.
 */
export function pruneReviewedKeyLines(sql: LimitSql, now: number): number {
  return sql.exec(`DELETE FROM reviewed_key_lines WHERE at < ? AND NOT EXISTS (SELECT 1 FROM pull_requests p
    WHERE lower(p.id) = lower(reviewed_key_lines.pr) AND p.head = reviewed_key_lines.head) RETURNING line`,
  now - REVIEWED_KEPT_MS).toArray().length;
}
