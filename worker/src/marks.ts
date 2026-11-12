/**
 * What the PR index has yet to read again, and when (docs/api.md, "Webhook reads"). A delivery says a PR may have
 * changed, never what it is now, and a busy org sends many for the same PR or head: a CI run's every check suite and
 * status, a bot's run of comments. Each mark is due a moment after the first delivery when the PR has been quiet, and
 * otherwise once its window since the last read has passed, so a burst costs one read per window, not one per delivery.
 *
 * - `full`: everything about the PR (`readPullRequests`): a PR event or a comment.
 * - `checks`: only its checks (`readChecks`): a check suite or a status. A full read due for the same PR covers it.
 *
 * A mark made while its read is in flight survives the read (`generation`), so nothing newer is ever lost.
 */
import type { LimitSql } from "./limit-counter.ts";
import type { PullRequestRef } from "./github.ts";

export type Scope = "full" | "checks";

/** A delivery after quiet waits this long, so the burst it starts is read once. */
export const BUSY_WINDOW_MS = 3_000;
/** A PR read again for its events no more than once in this long: a comment shows within it, mid-burst. */
export const PR_EVENT_WINDOW_MS = 15_000;
/** A PR's checks read again for check suites and statuses no more than once in this long. */
export const CHECKS_WINDOW_MS = 30_000;

const TABLES: Record<Scope, string> = { full: "dirty", checks: "dirty_checks" };
const WINDOWS: Record<Scope, number> = { full: PR_EVENT_WINDOW_MS, checks: CHECKS_WINDOW_MS };

/** A due mark: the PR, the generation it was read at, and (full) the generation of a checks mark the read covers. */
export interface DueMark {
  id: string;
  repo: string;
  number: number;
  generation: number;
  checksGeneration: number | null;
}

/** `dirty` predates `due_at`: an older one gains it, its marks due at once. */
export function createMarkTables(sql: LimitSql): void {
  for (const table of Object.values(TABLES)) {
    sql.exec(`CREATE TABLE IF NOT EXISTS ${table} (id TEXT PRIMARY KEY, repo TEXT, number INTEGER, generation INTEGER)`);
    const columns = sql.exec<{ name: string }>(`PRAGMA table_info(${table})`).toArray().map(({ name }) => name);
    for (const column of ["due_at", "urgent_generation"].filter((name) => !columns.includes(name))) {
      sql.exec(`ALTER TABLE ${table} ADD COLUMN ${column} INTEGER NOT NULL DEFAULT 0`);
    }
  }
  sql.exec("CREATE TABLE IF NOT EXISTS last_reads (id TEXT, scope TEXT, at INTEGER, PRIMARY KEY (id, scope))");
}

/**
 * When a delivery's read is due: `BUSY_WINDOW_MS` from now, or the scope's window after the PR's last read when that is
 * later. A full read counts as a checks read too.
 */
export function throttledDue(sql: LimitSql, id: string, scope: Scope, now: number): number {
  const scopes = scope === "full" ? ["full"] : ["full", "checks"];
  const last = sql.exec<{ at: number | null }>(
    `SELECT max(at) AS at FROM last_reads WHERE id = ? AND scope IN (${scopes.map(() => "?").join(", ")})`,
    id, ...scopes).toArray()[0]?.at ?? null;
  return Math.max(now + BUSY_WINDOW_MS, last === null ? 0 : last + WINDOWS[scope]);
}

/**
 * Marks a PR for a read due at `due`. A mark already waiting keeps the earlier time: a burst never pushes it back. An
 * `urgent` one (the person's own write) stays due then even when it lands during a read.
 */
export function mark(sql: LimitSql, ref: PullRequestRef, scope: Scope, due: number, urgent = false): void {
  sql.exec(`INSERT INTO ${TABLES[scope]} (id, repo, number, generation, due_at, urgent_generation)
    VALUES (?, ?, ?, 1, ?, ?)
    ON CONFLICT (id) DO UPDATE SET generation = generation + 1, due_at = min(due_at, excluded.due_at),
      urgent_generation = CASE WHEN ? THEN generation + 1 ELSE urgent_generation END`,
  ref.id, ref.repo, ref.number, due, urgent ? 1 : 0, urgent ? 1 : 0);
}

/** Marks GitHub could not answer wait until `due`, so a refusal is not asked again at once. */
export function postpone(sql: LimitSql, scope: Scope, ids: string[], due: number): void {
  for (const id of ids) {
    sql.exec(`UPDATE ${TABLES[scope]} SET due_at = max(due_at, ?) WHERE id = ?`, due, id);
  }
}

/**
 * The marks due by `now`, earliest first. A checks mark waits while a full read of the same PR is marked: that read
 * covers it.
 */
export function dueMarks(sql: LimitSql, scope: Scope, now: number, limit: number): DueMark[] {
  const query = scope === "full"
    ? `SELECT d.id, d.repo, d.number, d.generation, c.generation AS checksGeneration FROM dirty d
      LEFT JOIN dirty_checks c ON c.id = d.id WHERE d.due_at <= ? ORDER BY d.due_at LIMIT ?`
    : `SELECT id, repo, number, generation, NULL AS checksGeneration FROM dirty_checks
      WHERE due_at <= ? AND id NOT IN (SELECT id FROM dirty) ORDER BY due_at LIMIT ?`;
  return sql.exec<{ id: string; repo: string; number: number; generation: number; checksGeneration: number | null }>(
    query, now, limit).toArray();
}

/**
 * A read finished, and the PR's window starts now. Its mark goes, unless a delivery came during the read: that one is
 * due when the window ends. A full read also settles the checks mark it covered.
 */
export function finishRead(sql: LimitSql, scope: Scope, read: DueMark, now: number): void {
  sql.exec(`DELETE FROM ${TABLES[scope]} WHERE id = ? AND generation = ?`, read.id, read.generation);
  sql.exec(`UPDATE ${TABLES[scope]} SET due_at = max(due_at, CASE WHEN urgent_generation > ? THEN ? ELSE ? END)
    WHERE id = ?`, read.generation, now, now + WINDOWS[scope], read.id);
  if (scope === "full" && read.checksGeneration !== null) {
    sql.exec("DELETE FROM dirty_checks WHERE id = ? AND generation <= ?", read.id, read.checksGeneration);
  }
  sql.exec(`INSERT INTO last_reads (id, scope, at) VALUES (?, ?, ?)
    ON CONFLICT (id, scope) DO UPDATE SET at = excluded.at`, read.id, scope, now);
  sql.exec("DELETE FROM last_reads WHERE at < ?", now - Math.max(...Object.values(WINDOWS)));
}

/** A mark that names no PR a read can make: it goes, and nothing waits on it. */
export function dropMark(sql: LimitSql, id: string): void {
  sql.exec("DELETE FROM dirty WHERE id = ?", id);
  sql.exec("DELETE FROM dirty_checks WHERE id = ?", id);
}

/** When the next mark is due; null when none waits. A checks mark behind a full one waits on that one. */
export function nextDueAt(sql: LimitSql): number | null {
  return sql.exec<{ at: number | null }>(`SELECT min(at) AS at FROM (SELECT min(due_at) AS at FROM dirty
    UNION ALL SELECT min(due_at) FROM dirty_checks WHERE id NOT IN (SELECT id FROM dirty))`).toArray()[0]?.at ?? null;
}

/** The PRs marked, either scope. */
export function markedIds(sql: LimitSql): { id: string; repo: string }[] {
  return sql.exec<{ id: string; repo: string }>(
    "SELECT id, repo FROM dirty UNION SELECT id, repo FROM dirty_checks").toArray();
}
