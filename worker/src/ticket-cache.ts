// The Linear tickets the index's PRs name, kept so a PR read again asks Linear only for a key it has not checked within
// the hour. `tick` checks the held rows' keys again each hour, so a ticket that moves on in Linear moves on its row.
import { parseStoredTicket } from "./boundary.ts";
import type { LimitSql } from "./limit-counter.ts";
import type { Ticket } from "./tickets.ts";

/** How long Linear's answer about a key stands before the key is asked again. */
export const TICKET_FRESH_MS = 60 * 60_000;
/** The most keys one tick asks Linear about again: one call. */
export const TICKET_REFRESH_MAX = 50;

/** Asks Linear about some keys, as `lookUpTickets` does: a key it did not answer for is absent. */
export type AskLinear = (keys: string[]) => Promise<Map<string, Ticket>>;

/** `ticket` is null for a key Linear has not answered for yet. `pull_requests.ticket_keys` names each held PR's keys. */
export function createTicketsTable(sql: LimitSql): void {
  sql.exec("CREATE TABLE IF NOT EXISTS tickets (key TEXT PRIMARY KEY, ticket TEXT, checked_at INTEGER)");
  const columns = sql.exec<{ name: string }>("PRAGMA table_info(tickets)").toArray();
  if (!columns.some(({ name }) => name === "connection")) {
    sql.exec("ALTER TABLE tickets ADD COLUMN connection TEXT NOT NULL DEFAULT ''");
  }
}

/**
 * What Linear said about each key asked: a new answer replaces the stored one; a key it did not answer for keeps the
 * one stored and waits the hour too, so Linear being down is not asked again on every read. Answers the keys whose
 * ticket changed.
 */
function remember(sql: LimitSql, asked: string[], answer: ReadonlyMap<string, Ticket>, now: number, connection: string): string[] {
  const changed: string[] = [];
  for (const key of asked) {
    const ticket = answer.get(key);
    const held = sql.exec<{ ticket: string | null; connection: string }>(
      "SELECT ticket, connection FROM tickets WHERE key = ?", key).toArray()[0];
    if (ticket) {
      const text = JSON.stringify(ticket);
      if (held?.ticket !== text || held?.connection !== connection) {
        changed.push(key);
      }
      sql.exec(`INSERT INTO tickets (key, ticket, checked_at, connection) VALUES (?, ?, ?, ?)
        ON CONFLICT (key) DO UPDATE SET ticket = excluded.ticket, checked_at = excluded.checked_at,
          connection = excluded.connection`, key, text, now, connection);
    } else {
      if (held?.ticket && held.connection !== connection) {
        changed.push(key);
      }
      sql.exec(`INSERT INTO tickets (key, ticket, checked_at, connection) VALUES (?, NULL, ?, ?)
        ON CONFLICT (key) DO UPDATE SET checked_at = excluded.checked_at,
          ticket = CASE WHEN connection = excluded.connection THEN ticket ELSE NULL END,
          connection = excluded.connection`, key, now, connection);
    }
  }
  return changed;
}

/** Each key's ticket: as stored when it was checked within the hour, else asked of Linear in one call. */
export async function cachedTickets(
  sql: LimitSql, keys: string[], now: number, ask: AskLinear, connection = "",
): Promise<Map<string, Ticket>> {
  const found = new Map<string, Ticket>();
  const stale: string[] = [];
  for (const key of new Set(keys)) {
    const held = sql.exec<{ ticket: string | null; checked_at: number; connection: string }>(
      "SELECT ticket, checked_at, connection FROM tickets WHERE key = ? AND connection = ?", key, connection).toArray()[0];
    const ticket = parseStoredTicket(held?.ticket ?? null);
    if (ticket) {
      found.set(key, ticket);
    }
    if (!held || held.checked_at < now - TICKET_FRESH_MS) {
      stale.push(key);
    }
  }
  if (stale.length > 0) {
    const answer = await ask(stale);
    remember(sql, stale, answer, now, connection);
    for (const [key, ticket] of answer) {
      found.set(key, ticket);
    }
  }
  return found;
}

/**
 * The held PRs' keys not checked within the hour, asked again, up to `TICKET_REFRESH_MAX`; keys no held PR names are
 * dropped. Answers the PRs whose ticket changed, to be read again.
 */
export async function refreshTickets(
  sql: LimitSql, now: number, ask: AskLinear, connection = "",
): Promise<{ id: string; repo: string; number: number }[]> {
  sql.exec(`DELETE FROM tickets WHERE key NOT IN
    (SELECT k.value FROM pull_requests p, json_each(p.ticket_keys) k)`);
  const stale = sql.exec<{ key: string }>(`SELECT DISTINCT k.value AS key
    FROM pull_requests p, json_each(p.ticket_keys) k LEFT JOIN tickets t ON t.key = k.value
    WHERE t.checked_at IS NULL OR t.connection <> ? OR t.checked_at < ? LIMIT ?`,
  connection, now - TICKET_FRESH_MS, TICKET_REFRESH_MAX).toArray()
    .map((row) => row.key);
  if (stale.length === 0) {
    return [];
  }
  const changed = remember(sql, stale, await ask(stale), now, connection);
  if (changed.length === 0) {
    return [];
  }
  return sql.exec<{ id: string; repo: string; number: number }>(`SELECT DISTINCT p.id, p.repo, p.number
    FROM pull_requests p, json_each(p.ticket_keys) k WHERE k.value IN (SELECT value FROM json_each(?))`,
  JSON.stringify(changed)).toArray();
}

export function resetTickets(sql: LimitSql): { id: string; repo: string; number: number }[] {
  sql.exec("DELETE FROM tickets");
  sql.exec("UPDATE pull_requests SET ticket = NULL, tickets = '[]'");
  return sql.exec<{ id: string; repo: string; number: number }>(
    "SELECT id, repo, number FROM pull_requests WHERE list <> 'merged'").toArray();
}
