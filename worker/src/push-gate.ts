// The push gate (docs/api.md, "Alerts"): an alert waits until its PR's detail and diff are stored at the head it is about, so the phone's prefetch and a tap read them from R2, not from GitHub. It waits
// `ALERT_HOLD_MAX_MS` at most, then goes anyway.
import type { AlertKind, PrAlert } from "./alerts.ts";
import type { LimitSql } from "./limit-counter.ts";
import { prId, type RepoFullName } from "./ids.ts";

/** Long enough for a big diff on a busy GitHub; an alert later than this is worse than one opened from GitHub. */
export const ALERT_HOLD_MAX_MS = 30_000;

export function createHeldAlertsTable(sql: LimitSql): void {
  sql.exec(`CREATE TABLE IF NOT EXISTS held_alerts (key TEXT PRIMARY KEY, kind TEXT, repo TEXT, number INTEGER,
    head TEXT, title TEXT, held_at INTEGER)`);
}

/** An alert claimed (`alertKey`) and waiting for its PR's files. Holding it twice keeps the first. */
export function holdAlert(sql: LimitSql, key: string, alert: PrAlert, now: number): void {
  sql.exec(`INSERT INTO held_alerts (key, kind, repo, number, head, title, held_at) VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (key) DO NOTHING`, key, alert.kind, alert.repo, alert.number, alert.head, alert.title, now);
}

/** What the index holds of a PR, as the gate reads it. */
export type HeldRow = {
  head: string;
  diff_state: string;
};

type HeldAlertRow = {
  key: string; kind: AlertKind; repo: RepoFullName; number: number; head: string; title: string; held_at: number;
};

/**
 * Why an alert goes now. `ready`: its files are stored. `moved`: the PR's head moved on, so the files of the head it
 * names will never come. `timed_out`: it waited `ALERT_HOLD_MAX_MS`.
 */
export type ReleaseReason = "ready" | "moved" | "timed_out";

export interface Release {
  alert: PrAlert;
  heldMs: number;
  reason: ReleaseReason;
}

export interface GateDecision {
  release: Release[];
  /** Alerts whose PR left every list: nothing to open, so nothing is sent. */
  dropped: PrAlert[];
  /** When the gate must look again, at the latest: the first held alert's deadline. Null when none waits. */
  nextAt: number | null;
}

/** Takes every alert that may go now out of the table. */
export function releaseAlerts(sql: LimitSql, now: number): GateDecision {
  const held = sql.exec<HeldAlertRow>(
    "SELECT key, kind, repo, number, head, title, held_at FROM held_alerts ORDER BY held_at").toArray();
  const decision: GateDecision = { release: [], dropped: [], nextAt: null };
  for (const { key, held_at: heldAt, ...alert } of held) {
    const row = sql.exec<HeldRow>("SELECT head, diff_state FROM pull_requests WHERE id = ?",
      prId(alert.repo, alert.number)).toArray()[0];
    const reason = row ? reasonToGo(row, alert.head, now - heldAt) : null;
    if (row && reason === null) {
      const deadline = heldAt + ALERT_HOLD_MAX_MS;
      decision.nextAt = decision.nextAt === null ? deadline : Math.min(decision.nextAt, deadline);
      continue;
    }
    sql.exec("DELETE FROM held_alerts WHERE key = ?", key);
    if (reason) {
      decision.release.push({ alert, heldMs: now - heldAt, reason });
    } else {
      decision.dropped.push(alert);
    }
  }
  return decision;
}

function reasonToGo(row: HeldRow, head: string, heldMs: number): ReleaseReason | null {
  if (row.head !== head) {
    return "moved";
  }
  const isDiffSettled = row.diff_state === "ready" || row.diff_state === "too_large";
  if (isDiffSettled) {
    return "ready";
  }
  return heldMs >= ALERT_HOLD_MAX_MS ? "timed_out" : null;
}
