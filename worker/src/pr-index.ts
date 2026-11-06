import { claimOf, RECEIPT_KEPT_MS, type WriteClaim, type WriteReceipt } from "./write-receipts";
import { DurableObject } from "cloudflare:workers";
import { type ApnsHost, apnsJwt, pushMode, sendSilentPush, sendViaRelay } from "./apns";
import { aiJobs, type Env, isSet } from "./env";
import { isPairingRecord, type PairingRecord, pairingKey } from "./pairing";
import { fetchDiff, type PullRequest, readPullRequests, type RowStatus, searchListings } from "./github";
import { DEFAULT_CONTEXT } from "./key-lines";

const BUSY_WINDOW_MS = 3_000;
const READS_PER_PASS = 5;
const DIFFS_PER_PASS = 10;
const PUSH_SPACING_MS = 30 * 60_000;
const KEPT_EVENTS = 5_000;
const KEY_LINES_PER_PASS = 5;
/** A job that failed, say for want of credit, goes again after this long, so the list heals without being asked. */
const KEY_LINES_RETRY_MS = 30 * 60_000;
/** Raise it when what a row or detail holds changes shape: every held PR is then read again, once. */
const ROW_SHAPE = 7;
const LIST_ORDER = "CASE list WHEN 'mine' THEN 1 ELSE 0 END, updated_at DESC";

export function diffKey(repo: string, number: number, revision: string): string {
  return `${repo}/${number}/${revision}.diff`;
}

export function detailKey(repo: string, number: number, version: string): string {
  return `${repo}/${number}/detail/${version}.json`;
}

export interface Row {
  repo: string;
  number: number;
  title: string;
  head: string;
  revision: string;
  diff: string;
  detail: string;
  status: RowStatus | null;
  /** The context the phone can fetch key lines at for this head, once they are ready. */
  keyLines: number | null;
}

/**
 * A mirror of Jai's PRs. Webhooks and the poll only mark what looks different; `alarm` alone writes a PR, from a fresh
 * read of GitHub, so nothing older can land over something newer. Alarms never overlap, and a mark made during a read
 * survives it.
 */
export class PrIndex extends DurableObject<Env> {
  private readonly sql = this.ctx.storage.sql;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql.exec(`
      DROP TABLE IF EXISTS prs;
      CREATE TABLE IF NOT EXISTS pull_requests (id TEXT PRIMARY KEY, repo TEXT, number INTEGER, title TEXT, head TEXT,
        revision TEXT, list TEXT, updated_at TEXT, changed_at INTEGER, diff_state TEXT, diff_tried_at INTEGER);
      CREATE TABLE IF NOT EXISTS dirty (id TEXT PRIMARY KEY, repo TEXT, number INTEGER, generation INTEGER);
      CREATE TABLE IF NOT EXISTS devices (token TEXT PRIMARY KEY, host TEXT);
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER);
      CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, at INTEGER, kind TEXT, detail TEXT);
      CREATE TABLE IF NOT EXISTS writes (ref TEXT PRIMARY KEY, state TEXT, at INTEGER);
      CREATE TABLE IF NOT EXISTS paired (fingerprint TEXT PRIMARY KEY, role TEXT, label TEXT, paired_at INTEGER);
      CREATE TABLE IF NOT EXISTS spent_codes (code_hash TEXT PRIMARY KEY, at INTEGER);`);
    const columns = this.sql.exec<{ name: string }>("PRAGMA table_info(pull_requests)").toArray();
    if (!columns.some(({ name }) => name === "version")) {
      this.sql.exec("ALTER TABLE pull_requests ADD COLUMN version TEXT NOT NULL DEFAULT ''");
    }
    if (!columns.some(({ name }) => name === "status")) {
      this.sql.exec("ALTER TABLE pull_requests ADD COLUMN status TEXT");
    }
    if (!columns.some(({ name }) => name === "key_lines_queued")) {
      this.sql.exec("ALTER TABLE pull_requests ADD COLUMN key_lines_queued TEXT");
      this.sql.exec("ALTER TABLE pull_requests ADD COLUMN key_lines_ready TEXT");
    }
    if (!columns.some(({ name }) => name === "key_lines_tried_at")) {
      this.sql.exec("ALTER TABLE pull_requests ADD COLUMN key_lines_tried_at INTEGER");
    }
    if (!columns.some(({ name }) => name === "detail_version")) {
      this.sql.exec("ALTER TABLE pull_requests ADD COLUMN detail_version TEXT");
    }
  }

  rows(): { prs: Row[]; synced_at: number } {
    const rows = this.sql.exec<Omit<Row, "status"> & { status: string | null }>(`SELECT repo, number, title, head,
      revision, diff_state AS diff, COALESCE(detail_version, NULLIF(version, ''), updated_at) AS detail, status,
      CASE WHEN key_lines_ready = head THEN ${DEFAULT_CONTEXT} END AS keyLines
      FROM pull_requests
      ORDER BY ${LIST_ORDER}`).toArray();
    const prs = rows.map((row) => ({ ...row, status: row.status ? JSON.parse(row.status) as RowStatus : null }));
    return { prs, synced_at: this.meta("synced_at") };
  }

  /** A delivery. A PR no list holds and Jai has no part in is dropped here, so it never costs a GitHub read. */
  async mark(repo: string, number: number, involved: boolean): Promise<void> {
    const id = `${repo}#${number}`;
    if (!involved && !this.exists("pull_requests", id)) {
      return;
    }
    this.markDirty(id, repo, number);
    await this.ensureAlarm(BUSY_WINDOW_MS);
  }

  override async alarm(): Promise<void> {
    const dirty = this.sql.exec<{ id: string; repo: string; number: number; generation: number }>(
      "SELECT id, repo, number, generation FROM dirty LIMIT ?", READS_PER_PASS).toArray();
    if (dirty.length > 0) {
      const asked = new Set(this.sql.exec<{ id: string }>(
        "SELECT id FROM pull_requests WHERE list IN ('review', 'reviewed')").toArray().map((row) => row.id));
      const read = await readPullRequests(dirty, this.env, asked);
      for (const { id, generation } of dirty) {
        const pr = read.get(id);
        if (pr?.list) {
          await this.store(pr);
        } else {
          this.remove(id);
        }
        this.sql.exec("DELETE FROM dirty WHERE id = ? AND generation = ?", id, generation);
      }
    }
    await this.storeDiffs();
    await this.queueKeyLines();
    if (this.exists("dirty") || this.exists("pending")) {
      await this.ctx.storage.setAlarm(Date.now() + 250);
    }
  }

  /** Every minute: the safety net, because GitHub does not retry a failed delivery and personal repos send none. */
  async tick(now: number): Promise<void> {
    try {
      await this.compareWithGitHub();
      this.setMeta("synced_at", now);
      await this.queueKeyLines();
    } catch (error) {
      this.addEvent("poll_failed", { error: String(error) });
    }
    await this.pushIfDue(now);
  }

  private async compareWithGitHub(): Promise<void> {
    const listings = await searchListings(this.env);
    const held = this.sql.exec<{ id: string; repo: string; number: number; version: string; status: string | null }>(
      "SELECT id, repo, number, version, status FROM pull_requests").toArray();
    const isCurrentShape = this.meta("row_shape") >= ROW_SHAPE;
    const versions = new Map(held.map((row) => [row.id, row.status && isCurrentShape ? row.version : null]));
    this.setMeta("row_shape", ROW_SHAPE);
    for (const { id, repo, number, version, reviewedOnly } of listings.values()) {
      if (versions.get(id) !== version && (!reviewedOnly || versions.has(id))) {
        this.markDirty(id, repo, number);
      }
    }
    for (const { id, repo, number } of held) {
      if (!listings.has(id)) {
        this.markDirty(id, repo, number);
      }
    }
    if (this.exists("dirty") || this.exists("pending")) {
      await this.ensureAlarm(0);
    }
  }

  /** Whether this copy of a write goes to GitHub (`write-receipts.ts`). One that does is marked sending in the same turn. */
  claimWrite(ref: string, now: number): WriteClaim {
    this.sql.exec("DELETE FROM writes WHERE at < ?", now - RECEIPT_KEPT_MS);
    const receipt = this.sql.exec<WriteReceipt>("SELECT state, at FROM writes WHERE ref = ?", ref).toArray()[0] ?? null;
    const claim = claimOf(receipt, now);
    if (claim === "go") {
      this.sql.exec(`INSERT INTO writes (ref, state, at) VALUES (?, 'sending', ?)
        ON CONFLICT (ref) DO UPDATE SET state = 'sending', at = excluded.at`, ref, now);
    }
    return claim;
  }

  /** GitHub took it, or refused it: a refusal leaves no receipt, so the same write may be tried again. */
  finishWrite(ref: string, sent: boolean, now: number): void {
    if (sent) {
      this.sql.exec("UPDATE writes SET state = 'done', at = ? WHERE ref = ?", now, ref);
    } else {
      this.sql.exec("DELETE FROM writes WHERE ref = ?", ref);
    }
  }

  /**
   * A pairing code admits the device secret whose fingerprint this is (docs/api/pr-selfhost.md). The code is spent in
   * this object's own storage before anything is awaited, so two requests with it can't both pass. A `device` code
   * replaces every paired device, and the push registrations with them; an `app` code adds one.
   */
  async pair(codeHash: string, fingerprint: string, now: number): Promise<PairingRecord | null> {
    // A code lives 30 minutes and its record goes when it is used, so a day of spent hashes is plenty.
    this.sql.exec("DELETE FROM spent_codes WHERE at < ?", now - 86_400_000);
    const claimed = this.sql.exec(`INSERT INTO spent_codes (code_hash, at) VALUES (?, ?)
      ON CONFLICT (code_hash) DO NOTHING RETURNING code_hash`, codeHash, now).toArray().length > 0;
    if (!claimed) {
      return null;
    }
    const stored = await this.env.DIFFS.get(pairingKey(codeHash));
    const record: unknown = stored ? await stored.json().catch(() => null) : null;
    if (!isPairingRecord(record) || Date.parse(record.expires_at) <= now) {
      // A guess spends nothing: the hash of a code nobody minted is forgotten again.
      this.sql.exec("DELETE FROM spent_codes WHERE code_hash = ?", codeHash);
      return null;
    }
    await this.env.DIFFS.delete(pairingKey(codeHash));
    if (record.role === "device") {
      this.sql.exec("DELETE FROM paired");
      this.sql.exec("DELETE FROM devices");
    }
    this.sql.exec(`INSERT INTO paired (fingerprint, role, label, paired_at) VALUES (?, ?, ?, ?)
      ON CONFLICT (fingerprint) DO UPDATE SET role = excluded.role, label = excluded.label, paired_at = excluded.paired_at`,
    fingerprint, record.role, record.label, now);
    this.addEvent("paired", { role: record.role, label: record.label });
    return record;
  }

  isPaired(fingerprint: string): boolean {
    return this.sql.exec("SELECT 1 FROM paired WHERE fingerprint = ?", fingerprint).toArray().length > 0;
  }

  /** A device forgets itself: its secret stops working here. */
  unpair(fingerprint: string): void {
    this.sql.exec("DELETE FROM paired WHERE fingerprint = ?", fingerprint);
  }

  registerDevice(token: string, host: ApnsHost): void {
    this.sql.exec(`INSERT INTO devices (token, host) VALUES (?, ?)
      ON CONFLICT (token) DO UPDATE SET host = excluded.host`, token, host);
  }

  /** What the phone did. A sync's lag is how long each change it picked up took to reach it. */
  record(kind: string, detail: { changed?: string[]; complete?: boolean } & Record<string, unknown>): void {
    const now = Date.now();
    if (kind === "sync" && detail.complete) {
      this.setMeta("phone_synced_at", now);
    }
    const lags = (detail.changed ?? []).flatMap((id) => this.sql.exec<{ changed_at: number }>(
      "SELECT changed_at FROM pull_requests WHERE id = ?", id).toArray().map((row) => now - row.changed_at));
    this.addEvent(kind, { ...detail, changed: undefined, lags_ms: lags.length > 0 ? lags : undefined });
  }

  /** Why a push did or did not go, as of now. */
  pushState(): Record<string, number> {
    const count = (table: string) => this.sql.exec<{ n: number }>(`SELECT count(*) AS n FROM ${table}`).one().n;
    const production = this.sql.exec<{ n: number }>(
      "SELECT count(*) AS n FROM devices WHERE host = 'production'").one().n;
    return {
      changed_at: this.meta("changed_at"), pushed_at: this.meta("pushed_at"),
      phone_synced_at: this.meta("phone_synced_at"), devices: count("devices"), production, dirty: count("dirty"),
      pending: this.sql.exec<{ n: number }>(
        "SELECT count(*) AS n FROM pull_requests WHERE diff_state = 'pending'").one().n,
    };
  }

  events(limit: number): { at: number; kind: string; detail: string }[] {
    return this.sql.exec<{ at: number; kind: string; detail: string }>(
      "SELECT at, kind, detail FROM events ORDER BY id DESC LIMIT ?", limit).toArray();
  }

  private exists(what: "pull_requests" | "dirty" | "pending", id?: string): boolean {
    const query = {
      pull_requests: "SELECT 1 FROM pull_requests WHERE id = ?",
      dirty: "SELECT 1 FROM dirty LIMIT 1",
      pending: "SELECT 1 FROM pull_requests WHERE diff_state = 'pending' AND diff_tried_at < ? LIMIT 1",
    }[what];
    const parameter = what === "pending" ? Date.now() - 60_000 : id;
    return (parameter === undefined ? this.sql.exec(query) : this.sql.exec(query, parameter)).toArray().length > 0;
  }

  private markDirty(id: string, repo: string, number: number): void {
    this.sql.exec(`INSERT INTO dirty (id, repo, number, generation) VALUES (?, ?, ?, 1)
      ON CONFLICT (id) DO UPDATE SET generation = generation + 1`, id, repo, number);
  }

  private async ensureAlarm(delay: number): Promise<void> {
    if ((await this.ctx.storage.getAlarm()) === null) {
      await this.ctx.storage.setAlarm(Date.now() + delay);
    }
  }

  private addEvent(kind: string, detail: object): void {
    this.sql.exec("INSERT INTO events (at, kind, detail) VALUES (?, ?, ?)", Date.now(), kind, JSON.stringify(detail));
    this.sql.exec("DELETE FROM events WHERE id <= (SELECT max(id) FROM events) - ?", KEPT_EVENTS);
  }

  /**
   * The detail first: a row the phone can see always has one to fetch. Its version comes from what it says, because
   * GitHub does not move `updatedAt` for everything, resolving a thread among them, and the phone keeps each version.
   */
  private async store(pr: PullRequest): Promise<void> {
    const detail = JSON.stringify(pr.detail);
    const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(detail));
    const digest = Array.from(new Uint8Array(hash).slice(0, 8), (byte) => byte.toString(16).padStart(2, "0")).join("");
    const detailVersion = `${pr.version}.${digest}`;
    await this.env.DIFFS.put(detailKey(pr.repo, pr.number, detailVersion), detail);
    const id = `${pr.repo}#${pr.number}`;
    const held = this.sql.exec<{ detail_version: string | null }>(
      "SELECT detail_version FROM pull_requests WHERE id = ?", id).toArray()[0];
    this.sql.exec(`INSERT INTO pull_requests (id, repo, number, title, head, revision, list, updated_at, version,
        detail_version, status, changed_at, diff_state, diff_tried_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0)
      ON CONFLICT (id) DO UPDATE SET title = excluded.title, head = excluded.head, list = excluded.list,
        updated_at = excluded.updated_at, version = excluded.version, detail_version = excluded.detail_version,
        status = excluded.status, changed_at = excluded.changed_at,
        diff_state = CASE WHEN revision <> excluded.revision THEN 'pending' ELSE diff_state END,
        diff_tried_at = CASE WHEN revision <> excluded.revision THEN 0 ELSE diff_tried_at END,
        revision = excluded.revision`,
    id, pr.repo, pr.number, pr.title, pr.head, pr.revision, pr.list, pr.updatedAt, pr.version, detailVersion,
    JSON.stringify(pr.status), Date.now());
    if (held?.detail_version !== detailVersion) {
      this.setMeta("changed_at", Date.now());
    }
  }

  /** One job per new head of a PR waiting on Jai. `AiJobs` runs it, so this mirror never waits on a model. */
  private async queueKeyLines(): Promise<void> {
    if (!isSet(this.env.ANTHROPIC_API_KEY)) {
      return;
    }
    const due = this.sql.exec<{ id: string; repo: string; number: number; head: string }>(`SELECT id, repo, number, head
      FROM pull_requests WHERE list = 'review' AND diff_state = 'ready' AND (COALESCE(key_lines_queued, '') <> head
        OR (COALESCE(key_lines_ready, '') <> head AND COALESCE(key_lines_tried_at, 0) < ?))
      LIMIT ?`, Date.now() - KEY_LINES_RETRY_MS, KEY_LINES_PER_PASS).toArray();
    for (const { id, repo, number, head } of due) {
      this.sql.exec("UPDATE pull_requests SET key_lines_queued = ?, key_lines_tried_at = ? WHERE id = ?", head, Date.now(),
        id);
      await aiJobs(this.env).enqueue({ kind: "key_lines", repo, number, head, context: DEFAULT_CONTEXT });
    }
  }

  keyLinesReady(id: string, head: string): void {
    this.sql.exec("UPDATE pull_requests SET key_lines_ready = ? WHERE id = ? AND head = ?", head, id, head);
    this.setMeta("changed_at", Date.now());
  }

  private remove(id: string): void {
    if (this.sql.exec("DELETE FROM pull_requests WHERE id = ? RETURNING id", id).toArray().length > 0) {
      this.setMeta("changed_at", Date.now());
    }
  }

  /** Oldest try first, so a PR that keeps failing cannot starve the rest. */
  private async storeDiffs(): Promise<void> {
    const pending = this.sql.exec<{ id: string; repo: string; number: number; revision: string }>(`SELECT id, repo,
      number, revision FROM pull_requests WHERE diff_state = 'pending' AND diff_tried_at < ?
      ORDER BY diff_tried_at LIMIT ?`, Date.now() - 60_000, DIFFS_PER_PASS).toArray();
    await Promise.all(pending.map(async ({ id, repo, number, revision }) => {
      this.sql.exec("UPDATE pull_requests SET diff_tried_at = ? WHERE id = ?", Date.now(), id);
      const key = diffKey(repo, number, revision);
      const stored = await this.env.DIFFS.head(key);
      const response = stored ? null : await fetchDiff(repo, number, this.env);
      if (response?.ok) {
        await this.env.DIFFS.put(key, await response.arrayBuffer(), { httpMetadata: { contentType: "text/plain" } });
      }
      const state = stored || response?.ok ? "ready" : response?.status === 406 ? "too_large" : "pending";
      this.sql.exec("UPDATE pull_requests SET diff_state = ? WHERE id = ? AND revision = ?", state, id, revision);
    }));
  }

  /**
   * A push wakes the phone only for what it does not have yet. It does not wait for the mirror to go quiet: on a busy day
   * that never happens, and the phone publishes only what has fully arrived, so an early wake is harmless.
   */
  private async pushIfDue(now: number): Promise<void> {
    const changed = this.meta("changed_at");
    const isDue = changed > this.meta("pushed_at") && changed > this.meta("phone_synced_at")
      && now - this.meta("pushed_at") >= PUSH_SPACING_MS;
    if (!isDue) {
      return;
    }
    const mode = pushMode(this.env);
    if (mode === "none") {
      return;
    }
    const seconds = Math.floor(now / 1000);
    const jwt = mode === "apns" ? await apnsJwt(this.env, seconds) : "";
    // Production only: a Simulator registers on the sandbox host, and its wakes would read as the phone's in `/events`.
    const devices = this.sql.exec<{ token: string; host: ApnsHost }>(
      "SELECT token, host FROM devices WHERE host = 'production'").toArray();
    for (const { token, host } of devices) {
      const { status, reason } = mode === "relay" ? await sendViaRelay(token, host, this.env, seconds)
        : await sendSilentPush(token, host, jwt, this.env, seconds);
      this.addEvent("push", { status, reason });
      if (status === 200) {
        this.setMeta("pushed_at", now);
      } else if (status === 410 || reason === "BadDeviceToken" || reason === "Unregistered") {
        this.sql.exec("DELETE FROM devices WHERE token = ?", token);
      }
    }
  }

  private meta(key: string): number {
    return this.sql.exec<{ value: number }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0]?.value ?? 0;
  }

  private setMeta(key: string, value: number): void {
    this.sql.exec(`INSERT INTO meta (key, value) VALUES (?, ?)
      ON CONFLICT (key) DO UPDATE SET value = excluded.value`, key, value);
  }
}
