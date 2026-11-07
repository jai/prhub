/**
 * Counting toward the rate limits in `limits.ts`, over a Durable Object's SQLite: a person's `PrIndex` counts their own
 * requests, and an `IpLimit` (hosted) or the self-hosted `PrIndex` counts one IP's. Each request is one hit, under a
 * key: a repeat of the same key inside the window (the phone's outbox sending a write again with its `client_ref`) is
 * the hit already counted, so a retry never counts twice and never trips a limit it already passed.
 */
import type { LimitName, RateWindow } from "./limits.ts";

/** The slice of `SqlStorage` the counter uses; a test passes `node:sqlite` behind the same shape. */
export interface LimitSql {
  exec<Row extends Record<string, SqlStorageValue>>(query: string, ...bindings: unknown[]): { toArray(): Row[] };
}

export interface LimitCheck {
  readonly name: LimitName;
  readonly window: RateWindow;
}

export type LimitDecision = { allowed: true } | { allowed: false; name: LimitName; retryAfterMs: number };

export function createLimitHitsTable(sql: LimitSql): void {
  sql.exec(`CREATE TABLE IF NOT EXISTS limit_hits (name TEXT, subject TEXT, key TEXT, at INTEGER, expires_at INTEGER,
    PRIMARY KEY (name, subject, key))`);
}

/**
 * One request against every check: allowed only when each limit has room, and then counted in each at once. `subject`
 * is whose count it is within this object (`""` for the person who owns it, or an IP's hash). Expired hits go first,
 * every subject's, so the table holds at most each limit's count per subject.
 */
export function consumeLimits(
  sql: LimitSql, checks: readonly LimitCheck[], subject: string, key: string, now: number,
): LimitDecision {
  sql.exec("DELETE FROM limit_hits WHERE expires_at <= ?", now);
  const toCount: LimitCheck[] = [];
  for (const check of checks) {
    const since = now - check.window.windowMs;
    const isCounted = sql.exec("SELECT 1 FROM limit_hits WHERE name = ? AND subject = ? AND key = ? AND at > ?",
      check.name, subject, key, since).toArray().length > 0;
    if (isCounted) {
      continue;
    }
    const [{ hits, oldest }] = sql.exec<{ hits: number; oldest: number | null }>(`SELECT count(*) AS hits,
      min(at) AS oldest FROM limit_hits WHERE name = ? AND subject = ? AND at > ?`, check.name, subject, since).toArray();
    if (hits >= check.window.count) {
      return { allowed: false, name: check.name, retryAfterMs: (oldest ?? now) + check.window.windowMs - now };
    }
    toCount.push(check);
  }
  for (const check of toCount) {
    sql.exec(`INSERT INTO limit_hits (name, subject, key, at, expires_at) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (name, subject, key) DO UPDATE SET at = excluded.at, expires_at = excluded.expires_at`,
    check.name, subject, key, now, now + check.window.windowMs);
  }
  return { allowed: true };
}

/** When the last hit held expires, so an object that only counts can delete itself then; null when it holds none. */
export function lastExpiry(sql: LimitSql): number | null {
  const [{ last }] = sql.exec<{ last: number | null }>("SELECT max(expires_at) AS last FROM limit_hits").toArray();
  return last;
}
