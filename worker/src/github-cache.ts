// The PR index's own copy of what `.policy.yml` reads asked GitHub (`policy-github.ts`): one person's answers, kept in
// their index's storage, so a new isolate asks again with their ETags (a free 304) rather than paying for each.
import type { LimitSql } from "./limit-counter.ts";
import type { CachedAnswer, GitHubCache } from "./policy-github.ts";

/** An answer not asked about for a day is dropped: its repo or reviewer has gone quiet. */
const KEPT_MS = 86_400_000;

export function createGitHubCacheTable(sql: LimitSql): void {
  sql.exec("CREATE TABLE IF NOT EXISTS github_cache (key TEXT PRIMARY KEY, at INTEGER, etag TEXT, value TEXT)");
}

export function sqlCache(sql: LimitSql): GitHubCache {
  return {
    get<Value>(key: string): CachedAnswer<Value> | undefined {
      const row = sql.exec<{ at: number; etag: string | null; value: string }>(
        "SELECT at, etag, value FROM github_cache WHERE key = ?", key).toArray()[0];
      return row && { at: row.at, etag: row.etag, value: JSON.parse(row.value) as Value };
    },
    set(key, answer) {
      sql.exec(`INSERT INTO github_cache (key, at, etag, value) VALUES (?, ?, ?, ?)
        ON CONFLICT (key) DO UPDATE SET at = excluded.at, etag = excluded.etag, value = excluded.value`,
      key, answer.at, answer.etag, JSON.stringify(answer.value));
    },
  };
}

export function pruneGitHubCache(sql: LimitSql, now: number): void {
  sql.exec("DELETE FROM github_cache WHERE at < ?", now - KEPT_MS);
}
