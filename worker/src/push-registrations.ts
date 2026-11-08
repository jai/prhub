// A device's push registrations (docs/api.md, "Push registrations"): each APNs token is kept with the fingerprint of the
// bearer that registered it, so unpairing or signing out takes that device's registrations with it.
import type { ApnsHost } from "./apns.ts";
import type { DeviceToken, Fingerprint } from "./ids.ts";
import type { LimitSql } from "./limit-counter.ts";

/** Why the one-time cleanup removed a registration: kept by no fingerprint, or by one no longer paired or signed in. */
export const PushRegistrationPruneReason = { Unlinked: "unlinked", NotLive: "not_live" } as const;
export type PushRegistrationPruneReason = typeof PushRegistrationPruneReason[keyof typeof PushRegistrationPruneReason];

/** A removed registration as `/events` shows it: the token's first 8 hex characters, never all of it. */
export interface PrunedPushRegistration {
  token: string;
  host: ApnsHost;
  reason: PushRegistrationPruneReason;
}

const LOGGED_TOKEN_CHARACTERS = 8;

/** The table, and the `fingerprint` column that registrations made before it lack. */
export function createPushRegistrationsTable(sql: LimitSql): void {
  sql.exec("CREATE TABLE IF NOT EXISTS devices (token TEXT PRIMARY KEY, host TEXT)");
  const columns = sql.exec<{ name: string }>("PRAGMA table_info(devices)").toArray();
  if (!columns.some(({ name }) => name === "fingerprint")) {
    sql.exec("ALTER TABLE devices ADD COLUMN fingerprint TEXT");
  }
}

/** A token registered again moves to the device that sent it last. */
export function registerPushToken(sql: LimitSql, token: DeviceToken, host: ApnsHost, fingerprint: Fingerprint): void {
  sql.exec(`INSERT INTO devices (token, host, fingerprint) VALUES (?, ?, ?)
    ON CONFLICT (token) DO UPDATE SET host = excluded.host, fingerprint = excluded.fingerprint`, token, host, fingerprint);
}

/** Every registration this device made goes. Answers how many. */
export function forgetPushTokensOf(sql: LimitSql, fingerprint: Fingerprint): number {
  return sql.exec("DELETE FROM devices WHERE fingerprint = ? RETURNING token", fingerprint).toArray().length;
}

/** Every registration whose device is not in `live` goes, and so does every one kept before devices were recorded. */
export function pruneUnlinkedPushTokens(sql: LimitSql, live: ReadonlySet<string>): PrunedPushRegistration[] {
  const rows = sql.exec<{ token: string; host: ApnsHost; fingerprint: string | null }>(
    "SELECT token, host, fingerprint FROM devices").toArray();
  const pruned = rows.filter((row) => row.fingerprint === null || !live.has(row.fingerprint));
  for (const row of pruned) {
    sql.exec("DELETE FROM devices WHERE token = ?", row.token);
  }
  return pruned.map((row) => ({
    token: row.token.slice(0, LOGGED_TOKEN_CHARACTERS),
    host: row.host,
    reason: row.fingerprint === null ? PushRegistrationPruneReason.Unlinked : PushRegistrationPruneReason.NotLive,
  }));
}
