import { alarmToSet } from "./alarm";
import { claimOf, RECEIPT_KEPT_MS, type WriteClaim, type WriteReceipt } from "./write-receipts";
import { DurableObject } from "cloudflare:workers";
import { alertKey, alertKinds, alertMessage, alertsFor, type HeldStatus } from "./alerts";
import { createHeldAlertsTable, type HeldRow, holdAlert, releaseAlerts } from "./push-gate";
import {
  createPushRegistrationsTable, forgetPushTokensOf, pruneUnlinkedPushTokens, registerPushToken,
} from "./push-registrations";
import {
  type ApnsHost, apnsJwt, type PushMessage, pushMode, type PushOutcome, sendDirect, sendViaPager, sendViaRelay,
  SYNC_WAKE,
} from "./apns";
import { aiConfigOf } from "./config";
import { aiJobs, type Env, isSet, scopedKey } from "./env";
import { actingEnvFor } from "./hosted";
import type { SignedOutReason } from "./account-core";
import { fingerprintOf, type PairingRecord, pairingKey, parsePairingRecord } from "./pairing";
import {
  detailVersionOf, liveDiff, type OpenRowStatus, type PullRequest, type PullRequestRef, readPullRequests, type RowStatus,
  searchListings,
} from "./github";
import { parseRowStatus } from "./boundary";
import {
  type CodeHash, type DeviceToken, type Fingerprint, parseRepoFullName, parseSha, prId, type PrId, type RepoFullName,
  type Sha,
} from "./ids";
import { putVersioned, storeDiff } from "./versioned";
import { newRateLimitState } from "./rate-limit";
import { DEFAULT_CONTEXT } from "./key-lines";
import { consumeLimits, createLimitHitsTable, type LimitCheck, type LimitDecision } from "./limit-counter";
import { indexedPullRequestsMaxOf, LimitName, limitsOf, retentionOf } from "./limits";
import { sweepClosedPullRequests } from "./retention";
import {
  type CarriedIndexCounts, type CarriedIndexState, readCarriedIndexState, writeCarriedIndexState,
} from "./carry";
import {
  createReviewedKeyLinesTable, forgetReviewedKeyLinesOf, markKeyLine, pruneReviewedKeyLines, type ReviewedKeyLines,
  reviewedKeyLines,
} from "./reviewed-key-lines";

const BUSY_WINDOW_MS = 3_000;
/** The push that asks a hosted person to sign in again; the app shows Sign in with GitHub when it opens. */
const SIGN_IN_AGAIN: PushMessage = {
  pushType: "alert", priority: 10, collapseId: "prhub-sign-in", lifetimeSeconds: 7 * 86_400,
  payload: { aps: { alert: { title: "PRHub", body: "Sign in with GitHub again to keep your pull requests up to date." } },
    reason: "signed_out" },
};
const READS_PER_PASS = 5;
/** A failed read tries again this soon, every time: GitHub's outage, or a token being replaced, ends. */
const READ_RETRY_MS = 30_000;

const DIFFS_PER_PASS = 10;
const PUSH_SPACING_MS = 30 * 60_000;
const KEPT_EVENTS = 5_000;
/** An alert's key outlives any re-request worth hushing; a month of them is a few hundred rows. */
const ALERTS_KEPT_MS = 30 * 86_400_000;
const KEY_LINES_PER_PASS = 5;
/** A job that failed, say for want of credit, goes again after this long, so the list heals without being asked. */
const KEY_LINES_RETRY_MS = 30 * 60_000;
/** Raise it when what a row or detail holds changes shape: every held PR is then read again, once. */
const ROW_SHAPE = 8;
/** The retention sweep (`retention.ts`) runs at most this often. */
const RETENTION_SWEEP_MS = 86_400_000;
const LIST_ORDER = "CASE list WHEN 'mine' THEN 1 ELSE 0 END, updated_at DESC";

export function diffKey(repo: string, number: number, revision: string): string {
  return `${repo}/${number}/${revision}.diff`;
}

export function detailKey(repo: string, number: number, version: string): string {
  return `${repo}/${number}/detail/${version}.json`;
}

/** A PR the index holds, as a ref; null for a row whose repo is not `owner/name`, which no route can make. */
function refOf(row: { repo: string; number: number }): PullRequestRef | null {
  const repo = parseRepoFullName(row.repo);
  return repo && { id: prId(repo, row.number), repo, number: row.number };
}

/** A PR read with a list to go on. */
type Listed = PullRequest & { status: OpenRowStatus };

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
    this.createTables();
  }

  /** The schema, and each column added since: run on every start, and again after `deleteEverything`. */
  private createTables(): void {
    this.sql.exec(`
      DROP TABLE IF EXISTS prs;
      CREATE TABLE IF NOT EXISTS pull_requests (id TEXT PRIMARY KEY, repo TEXT, number INTEGER, title TEXT, head TEXT,
        revision TEXT, list TEXT, updated_at TEXT, changed_at INTEGER, diff_state TEXT, diff_tried_at INTEGER);
      CREATE TABLE IF NOT EXISTS dirty (id TEXT PRIMARY KEY, repo TEXT, number INTEGER, generation INTEGER);
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER);
      CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, at INTEGER, kind TEXT, detail TEXT);
      CREATE TABLE IF NOT EXISTS writes (ref TEXT PRIMARY KEY, state TEXT, at INTEGER);
      CREATE TABLE IF NOT EXISTS paired (fingerprint TEXT PRIMARY KEY, role TEXT, label TEXT, paired_at INTEGER);
      CREATE TABLE IF NOT EXISTS spent_codes (code_hash TEXT PRIMARY KEY, at INTEGER);
      CREATE TABLE IF NOT EXISTS alerts (key TEXT PRIMARY KEY, at INTEGER);`);
    createLimitHitsTable(this.sql);
    createHeldAlertsTable(this.sql);
    createPushRegistrationsTable(this.sql);
    createReviewedKeyLinesTable(this.sql);
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
    return { prs: this.selectRows(`ORDER BY ${LIST_ORDER}`), synced_at: this.meta("synced_at") };
  }

  /** The rows of `GET /prs`, chosen and ordered by `rest`: one SELECT, so an alert's row is the list's row. */
  private selectRows(rest: string, ...bindings: unknown[]): Row[] {
    const rows = this.sql.exec<Omit<Row, "status"> & { status: string | null }>(`SELECT repo, number, title, head,
      revision, diff_state AS diff, COALESCE(detail_version, NULLIF(version, ''), updated_at) AS detail, status,
      CASE WHEN key_lines_ready = head THEN ${DEFAULT_CONTEXT} END AS keyLines
      FROM pull_requests ${rest}`, ...bindings).toArray();
    return rows.map((row) => ({ ...row, status: parseRowStatus(row.status) }));
  }

  /** A delivery. A PR no list holds and Jai has no part in is dropped here, so it never costs a GitHub read. */
  async mark(repo: RepoFullName, number: number, involved: boolean): Promise<void> {
    const id = prId(repo, number);
    if (!involved && !this.exists("pull_requests", id)) {
      return;
    }
    this.markDirty(id, repo, number);
    await this.ensureAlarm(BUSY_WINDOW_MS);
  }

  /** A check suite or a status on a commit: each held PR at that head is read again, for its checks. */
  async markHead(repo: RepoFullName, sha: Sha): Promise<void> {
    const held = this.sql.exec<{ id: string; repo: string; number: number }>(
      "SELECT id, repo, number FROM pull_requests WHERE repo = ? AND head = ?", repo, sha).toArray();
    for (const row of held) {
      const ref = refOf(row);
      if (ref) {
        this.markDirty(ref.id, ref.repo, ref.number);
      }
    }
    if (held.length > 0) {
      await this.ensureAlarm(BUSY_WINDOW_MS);
    }
  }

  /** A read pass, then the alerts it made ready (`push-gate.ts`), which go even when the pass could not read. */
  override async alarm(): Promise<void> {
    const env = await this.actingEnv();
    await this.readMarked(env);
    await this.sendHeldAlerts(env);
  }

  private async readMarked(env: Env | null): Promise<void> {
    const marked = this.sql.exec<{ id: string; repo: string; number: number; generation: number }>(
      "SELECT id, repo, number, generation FROM dirty LIMIT ?", READS_PER_PASS).toArray();
    const dirty = marked.flatMap((row) => {
      const ref = refOf(row);
      if (!ref) {
        this.sql.exec("DELETE FROM dirty WHERE id = ?", row.id);
      }
      return ref ? [{ ...ref, generation: row.generation }] : [];
    });
    if (!env) {
      // A hosted person signed out: nothing is read until they sign in again and their account ticks this index.
      return;
    }
    const waitUntil = this.rateLimitedUntil(Date.now());
    if (waitUntil !== null) {
      // GitHub asked this token to wait, or its hour runs low: what is marked keeps until the reset.
      await this.ctx.storage.setAlarm(waitUntil);
      return;
    }
    if (dirty.length > 0) {
      const asked = new Set(this.sql.exec<{ id: string }>(
        "SELECT id FROM pull_requests WHERE list IN ('review', 'reviewed')").toArray().map((row) => row.id));
      let read: Awaited<ReturnType<typeof readPullRequests>>;
      try {
        read = await readPullRequests(dirty, env, asked);
      } catch (error) {
        // Not thrown: Cloudflare would retry it later and later, and new work would wait behind that retry.
        this.addEvent("read_failed", { error: String(error) });
        this.noteRateLimit(env);
        await this.ctx.storage.setAlarm(this.rateLimitedUntil(Date.now()) ?? Date.now() + READ_RETRY_MS);
        return;
      }
      for (const { id, generation } of dirty) {
        const pr = read.get(id);
        if (pr?.status && !this.isFullFor(id)) {
          const listed: Listed = { ...pr, status: pr.status };
          this.holdAlertsOn(listed);
          await this.store(listed, env);
        } else if (pr?.status) {
          this.addEvent("limit_reached", { limit: LimitName.IndexedPullRequestsMax, pr: id });
        } else {
          this.remove(id);
        }
        this.sql.exec("DELETE FROM dirty WHERE id = ? AND generation = ?", id, generation);
      }
    }
    await this.storeDiffs(env);
    await this.queueKeyLines(env);
    this.noteRateLimit(env);
    if (this.exists("dirty") || this.exists("pending")) {
      await this.ctx.storage.setAlarm(this.rateLimitedUntil(Date.now()) ?? Date.now() + 250);
    }
  }

  /** Every minute: the safety net, because GitHub does not retry a failed delivery and personal repos send none. */
  async tick(now: number): Promise<void> {
    if (!this.meta("user_id")) {
      this.prunePushRegistrationsOnce(await this.selfHostedDevices());
    }
    const env = await this.actingEnv();
    if (!env) {
      return;
    }
    if (this.rateLimitedUntil(now) === null) {
      try {
        await this.compareWithGitHub(env);
        this.setMeta("synced_at", now);
        await this.queueKeyLines(env);
      } catch (error) {
        this.addEvent("poll_failed", { error: String(error) });
      }
      this.noteRateLimit(env);
      if (isSet(env.SIGNED_IN_USER_ID) && env.GITHUB_RATE) {
        // What one poll costs a hosted person's hour (docs/plans/github-app.md, "Tokens"): a tenth of it is the target.
        const { calls, remaining, limit } = env.GITHUB_RATE;
        this.addEvent("polled", { calls, remaining, limit });
      }
    }
    this.sql.exec("DELETE FROM alerts WHERE at < ?", now - ALERTS_KEPT_MS);
    pruneReviewedKeyLines(this.sql, now);
    await this.sweepIfDue(env, now);
    await this.pushIfDue(now);
  }

  /** Once a day when retention is on: stored objects of PRs off the list past it go (`retention.ts`). */
  private async sweepIfDue(env: Env, now: number): Promise<void> {
    const retention = retentionOf(limitsOf(this.env));
    if (retention === null || now - this.meta("retention_swept_at") < RETENTION_SWEEP_MS) {
      return;
    }
    this.setMeta("retention_swept_at", now);
    const held = new Set(this.sql.exec<{ id: string }>("SELECT id FROM pull_requests").toArray()
      .map((row) => row.id.toLowerCase()));
    try {
      const deleted = await sweepClosedPullRequests(env.DIFFS, scopedKey(env, ""), (id) => held.has(id.toLowerCase()),
        now - retention);
      this.addEvent("retention_swept", { deleted });
    } catch (error) {
      this.addEvent("retention_failed", { error: String(error) });
    }
  }

  private async compareWithGitHub(env: Env): Promise<void> {
    const listings = await searchListings(env);
    const held = this.sql.exec<{ id: string; repo: string; number: number; version: string; status: string | null }>(
      "SELECT id, repo, number, version, status FROM pull_requests").toArray();
    const isCurrentShape = this.meta("row_shape") >= ROW_SHAPE;
    const versions = new Map<string, string | null>(
      held.map((row) => [row.id, row.status && isCurrentShape ? row.version : null]));
    this.setMeta("row_shape", ROW_SHAPE);
    for (const { id, repo, number, version, reviewedOnly } of listings.values()) {
      if (versions.get(id) !== version && (!reviewedOnly || versions.has(id))) {
        this.markDirty(id, repo, number);
      }
    }
    for (const row of held) {
      const ref = refOf(row);
      if (ref && !listings.has(ref.id)) {
        this.markDirty(ref.id, ref.repo, ref.number);
      }
    }
    if (this.exists("dirty") || this.exists("pending")) {
      await this.ensureAlarm(0);
    }
  }

  /**
   * The alerts a fresh read calls for, each claimed in storage, so the same PR and head never alerts twice
   * (`alerts.ts`), and held until its PR's files are stored (`push-gate.ts`). Read before `store` overwrites what was
   * held.
   */
  private holdAlertsOn(pr: Listed): void {
    const kinds = alertKinds(this.env);
    if (kinds.size === 0) {
      return;
    }
    const heldRow = this.sql.exec<{ status: string | null }>(
      "SELECT status FROM pull_requests WHERE id = ?", prId(pr.repo, pr.number)).toArray()[0];
    const held: HeldStatus = parseRowStatus(heldRow?.status ?? null);
    const now = Date.now();
    const read = { ...pr, list: pr.status.list, review: pr.status.review };
    for (const alert of alertsFor(held, read, kinds, now)) {
      const key = alertKey(alert);
      const claimed = this.sql.exec(`INSERT INTO alerts (key, at) VALUES (?, ?) ON CONFLICT (key) DO NOTHING
        RETURNING key`, key, now).toArray().length > 0;
      if (claimed) {
        holdAlert(this.sql, key, alert, now);
      }
    }
  }

  /**
   * The held alerts whose PR's files are stored, or that waited long enough, each with how long it was held in
   * `/events` (`alert` and `push_delayed`). One still waiting has an alarm at its deadline.
   */
  private async sendHeldAlerts(env: Env | null): Promise<void> {
    const makesKeyLines = env !== null && isSet(env.ANTHROPIC_API_KEY);
    const keyLinesOn = (row: HeldRow) => makesKeyLines && row.list === "review" && row.diff_state === "ready";
    const now = Date.now();
    const { release, dropped, nextAt } = releaseAlerts(this.sql, now, keyLinesOn);
    for (const alert of dropped) {
      this.addEvent("alert_dropped", { kind: alert.kind, pr: prId(alert.repo, alert.number) });
    }
    await Promise.all(release.map(({ alert, heldMs, reason }) => {
      const pr = prId(alert.repo, alert.number);
      const row = this.selectRows("WHERE id = ?", pr)[0] ?? null;
      this.addEvent("push_delayed", { kind: alert.kind, pr, ms: heldMs, reason });
      // This instance's own record of what it said, under `/events`: never shared with another instance's.
      return this.sendToDevices(alertMessage(alert, row), "alert",
        { kind: alert.kind, pr, title: alert.title, held_ms: heldMs });
    }));
    if (nextAt !== null) {
      await this.ensureAlarm(Math.max(0, nextAt - now));
    }
  }

  /** Whether `GET /repos` may read GitHub now: not when it did within `gapMs`. Claimed in the same turn. */
  claimRepoRefresh(now: number, gapMs: number): boolean {
    if (now - this.meta("repos_tried_at") < gapMs) {
      return false;
    }
    this.setMeta("repos_tried_at", now);
    return true;
  }

  /** How many of the list's PRs each repo holds: the repo index's liveliest relevance hint. */
  listedCounts(): Record<string, number> {
    const rows = this.sql.exec<{ repo: string; n: number }>(
      "SELECT repo, count(*) AS n FROM pull_requests GROUP BY repo").toArray();
    return Object.fromEntries(rows.map(({ repo, n }) => [repo, n]));
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

  /** One request against this person's (or, self-hosted, one IP's) limits (`limit-counter.ts`). */
  consumeLimits(checks: LimitCheck[], subject: string, key: string, now: number): LimitDecision {
    return consumeLimits(this.sql, checks, subject, key, now);
  }

  /** The person lost these repos (an installation removed them, or was suspended or deleted): their rows go now. */
  dropRepos(repos: string[]): void {
    const names = new Set(repos.map((repo) => repo.toLowerCase()));
    const held = this.sql.exec<{ id: string; repo: string }>("SELECT id, repo FROM pull_requests").toArray();
    for (const row of held.filter((one) => names.has(one.repo.toLowerCase()))) {
      this.remove(row.id);
    }
    const dirty = this.sql.exec<{ id: string; repo: string }>("SELECT id, repo FROM dirty").toArray();
    for (const row of dirty.filter((one) => names.has(one.repo.toLowerCase()))) {
      this.sql.exec("DELETE FROM dirty WHERE id = ?", row.id);
    }
    for (const repo of repos) {
      forgetReviewedKeyLinesOf(this.sql, repo);
    }
  }

  /** The key lines checked off on a PR at `head` (`reviewed-key-lines.ts`). */
  reviewedKeyLines(pr: PrId, head: Sha): ReviewedKeyLines {
    return reviewedKeyLines(this.sql, pr, head);
  }

  /** One key line checked off or back on; null when the head holds as many as it may. */
  markKeyLine(pr: PrId, head: Sha, line: string, reviewed: boolean, now: number): ReviewedKeyLines | null {
    return markKeyLine(this.sql, pr, head, line, reviewed, now);
  }

  /**
   * A pairing code admits the device secret whose fingerprint this is (docs/api.md). The code is spent in
   * this object's own storage before anything is awaited, so two requests with it can't both pass. A `device` code
   * replaces every paired device, and the push registrations with them; an `app` code adds one.
   */
  async pair(codeHash: CodeHash, fingerprint: Fingerprint, now: number): Promise<PairingRecord | null> {
    // A code lives 30 minutes and its record goes when it is used, so a day of spent hashes is plenty.
    this.sql.exec("DELETE FROM spent_codes WHERE at < ?", now - 86_400_000);
    const claimed = this.sql.exec(`INSERT INTO spent_codes (code_hash, at) VALUES (?, ?)
      ON CONFLICT (code_hash) DO NOTHING RETURNING code_hash`, codeHash, now).toArray().length > 0;
    if (!claimed) {
      return null;
    }
    const stored = await this.env.DIFFS.get(pairingKey(codeHash));
    const record = parsePairingRecord(stored ? await stored.json().catch(() => null) : null);
    if (!record || Date.parse(record.expires_at) <= now) {
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

  isPaired(fingerprint: Fingerprint): boolean {
    return this.sql.exec("SELECT 1 FROM paired WHERE fingerprint = ?", fingerprint).toArray().length > 0;
  }

  /**
   * A device forgets itself: its secret stops working everywhere at once, as every request asks `isPaired`, and its
   * push registrations go, so no alert reaches a phone that left.
   */
  unpair(fingerprint: Fingerprint): void {
    this.sql.exec("DELETE FROM paired WHERE fingerprint = ?", fingerprint);
    this.addEvent("unpaired", { push_registrations: forgetPushTokensOf(this.sql, fingerprint) });
  }

  registerDevice(token: DeviceToken, host: ApnsHost, fingerprint: Fingerprint): void {
    registerPushToken(this.sql, token, host, fingerprint);
  }

  /** Hosted: one phone signed out, and its push registrations go with its session. */
  forgetPushRegistrationsOf(fingerprint: Fingerprint): void {
    this.addEvent("device_signed_out", { push_registrations: forgetPushTokensOf(this.sql, fingerprint) });
  }

  /**
   * Once per index: registrations kept before each was tied to its device, and those of devices no longer paired or
   * signed in (`live`), go. What went is in `/events` as `push_registrations_pruned`.
   */
  prunePushRegistrationsOnce(live: string[]): void {
    if (this.meta("push_registrations_pruned_at")) {
      return;
    }
    const removed = pruneUnlinkedPushTokens(this.sql, new Set(live));
    this.setMeta("push_registrations_pruned_at", Date.now());
    this.addEvent("push_registrations_pruned", { removed });
  }

  /** Self-hosted: the paired devices, and Jai's app's `APP_TOKEN` when it is set. */
  private async selfHostedDevices(): Promise<string[]> {
    const paired = this.sql.exec<{ fingerprint: string }>("SELECT fingerprint FROM paired").toArray()
      .map((row) => row.fingerprint);
    return isSet(this.env.APP_TOKEN) ? [...paired, await fingerprintOf(this.env.APP_TOKEN)] : paired;
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
  /** The reviewed key-line ticks, for a move to another Worker (`carry.ts`). */
  exportCarried(): CarriedIndexState {
    return readCarriedIndexState(this.sql);
  }

  /** What `exportCarried` gave on the Worker before, added where missing, each carried PR then read from GitHub. */
  async importCarried(state: CarriedIndexState): Promise<CarriedIndexCounts> {
    const counts = writeCarriedIndexState(this.sql, state);
    for (const { repo, number } of state.reviewedPullRequests) {
      const name = parseRepoFullName(repo);
      if (name) {
        this.markDirty(prId(name, number), name, number);
      }
    }
    await this.ensureAlarm(0);
    return counts;
  }

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

  /** Whether a PR not held yet must wait: the index holds `indexed_pull_requests_max` already. */
  private isFullFor(id: string): boolean {
    const max = indexedPullRequestsMaxOf(limitsOf(this.env));
    return max !== null && !this.exists("pull_requests", id)
      && this.sql.exec<{ n: number }>("SELECT count(*) AS n FROM pull_requests").one().n >= max;
  }

  private markDirty(id: PrId, repo: RepoFullName, number: number): void {
    this.sql.exec(`INSERT INTO dirty (id, repo, number, generation) VALUES (?, ?, ?, 1)
      ON CONFLICT (id) DO UPDATE SET generation = generation + 1`, id, repo, number);
  }

  private async ensureAlarm(delay: number): Promise<void> {
    const now = Date.now();
    const at = alarmToSet(await this.ctx.storage.getAlarm(), now + delay, now);
    if (at !== null) {
      await this.ctx.storage.setAlarm(at);
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
  private async store(pr: Listed, env: Env): Promise<void> {
    const detailVersion = await detailVersionOf(pr);
    await putVersioned(env.DIFFS, scopedKey(env, detailKey(pr.repo, pr.number, detailVersion)), detailVersion,
      JSON.stringify(pr.detail), "application/json");
    const id = prId(pr.repo, pr.number);
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
    id, pr.repo, pr.number, pr.title, pr.head, pr.revision, pr.status.list, pr.updatedAt, pr.version, detailVersion,
    JSON.stringify(pr.status), Date.now());
    if (held?.detail_version !== detailVersion) {
      this.setMeta("changed_at", Date.now());
    }
  }

  /** One job per new head of a PR waiting on Jai. `AiJobs` runs it, so this mirror never waits on a model. */
  private async queueKeyLines(env: Env): Promise<void> {
    if (!isSet(env.ANTHROPIC_API_KEY)) {
      return;
    }
    const due = this.sql.exec<{ id: string; repo: string; number: number; head: string }>(`SELECT id, repo, number, head
      FROM pull_requests WHERE list = 'review' AND diff_state = 'ready' AND (COALESCE(key_lines_queued, '') <> head
        OR (COALESCE(key_lines_ready, '') <> head AND COALESCE(key_lines_tried_at, 0) < ?))
      LIMIT ?`, Date.now() - KEY_LINES_RETRY_MS, KEY_LINES_PER_PASS).toArray();
    for (const row of due) {
      this.sql.exec("UPDATE pull_requests SET key_lines_queued = ?, key_lines_tried_at = ? WHERE id = ?", row.head,
        Date.now(), row.id);
      const head = parseSha(row.head);
      const ref = refOf(row);
      if (!head || !ref) {
        continue;
      }
      await aiJobs(env).enqueue({
        kind: "key_lines", repo: ref.repo, number: ref.number, head, context: DEFAULT_CONTEXT, choice: aiConfigOf(env).defaults.key_lines,
      }, isSet(env.SIGNED_IN_USER_ID) ? env.SIGNED_IN_USER_ID : null);
    }
  }

  /** Key lines landed: an alert held for them (`push-gate.ts`) may go now. */
  async keyLinesReady(id: PrId, head: Sha): Promise<void> {
    this.sql.exec("UPDATE pull_requests SET key_lines_ready = ? WHERE id = ? AND head = ?", head, id, head);
    this.setMeta("changed_at", Date.now());
    if (this.sql.exec("SELECT 1 FROM held_alerts LIMIT 1").toArray().length > 0) {
      await this.ensureAlarm(0);
    }
  }

  private remove(id: string): void {
    if (this.sql.exec("DELETE FROM pull_requests WHERE id = ? RETURNING id", id).toArray().length > 0) {
      this.setMeta("changed_at", Date.now());
    }
  }

  /**
   * Oldest try first, so a PR that keeps failing cannot starve the rest. A diff read after the head moved stays pending:
   * the index reads the PR again, and the row moves to the new revision.
   */
  private async storeDiffs(env: Env): Promise<void> {
    const pending = this.sql.exec<{ id: string; repo: string; number: number; revision: string }>(`SELECT id, repo,
      number, revision FROM pull_requests WHERE diff_state = 'pending' AND diff_tried_at < ?
      ORDER BY diff_tried_at LIMIT ?`, Date.now() - 60_000, DIFFS_PER_PASS).toArray();
    await Promise.all(pending.map(async ({ id, repo, number, revision }) => {
      this.sql.exec("UPDATE pull_requests SET diff_tried_at = ? WHERE id = ?", Date.now(), id);
      const state = await storeDiff(env.DIFFS, scopedKey(env, diffKey(repo, number, revision)), revision,
        () => liveDiff(repo, number, env));
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
    if (await this.sendToDevices(SYNC_WAKE, "push", {})) {
      this.setMeta("pushed_at", now);
    }
  }

  /**
   * One message to every production device, each outcome in `/events` under `kind`. Production only: a Simulator
   * registers on the sandbox host, and its pushes would read as the phone's. True when Apple took it for any device. A
   * token Apple calls dead is forgotten.
   */
  /**
   * A Worker that imports this index (`lib.ts`) delivers its pushes itself, to its own devices: it overrides this. Null:
   * this Worker pushes, as `pushMode` says.
   */
  protected deliverByHost(_message: PushMessage): Promise<PushOutcome> | null {
    return null;
  }

  private async sendToDevices(message: PushMessage, kind: string, detail: object): Promise<boolean> {
    const byHost = this.deliverByHost(message);
    if (byHost) {
      const { status, reason } = await byHost;
      this.addEvent(kind, { ...detail, via: "host", status, reason });
      return status === 200;
    }
    const mode = pushMode(this.env);
    if (mode === "none") {
      return false;
    }
    if (mode === "pager") {
      const { status, reason } = await sendViaPager(this.env, message);
      this.addEvent(kind, { ...detail, via: "agent-pager", status, reason });
      return status === 200;
    }
    const seconds = Math.floor(Date.now() / 1000);
    const jwt = mode === "apns" ? await apnsJwt(this.env, seconds) : "";
    const devices = this.sql.exec<{ token: string; host: ApnsHost }>(
      "SELECT token, host FROM devices WHERE host = 'production'").toArray();
    let delivered = false;
    for (const { token, host } of devices) {
      const { status, reason } = mode === "relay" ? await sendViaRelay(token, host, this.env, seconds, message)
        : await sendDirect(token, host, jwt, this.env, seconds, message);
      this.addEvent(kind, { ...detail, status, reason });
      if (status === 200) {
        delivered = true;
      } else if (status === 410 || reason === "BadDeviceToken" || reason === "Unregistered") {
        this.sql.exec("DELETE FROM devices WHERE token = ?", token);
      }
    }
    return delivered;
  }

  /**
   * Hosted mode: this index is one signed-in person's (`user:<id>`). Kept here because an object does not know its own
   * name, and its alarm must find their token.
   */
  bindUser(userId: number): void {
    this.setMeta("user_id", userId);
  }

  /** GitHub stopped honouring the person's tokens: ask each phone to sign in again (docs/api.md, "Hosted sign-in"). */
  async signedOut(reason: SignedOutReason): Promise<void> {
    await this.sendToDevices(SIGN_IN_AGAIN, "signed_out", { reason });
  }

  /** The person's last phone signed out: no push goes anywhere until one signs in and registers again. */
  forgetDevices(): void {
    this.sql.exec("DELETE FROM devices");
  }

  /** Delete Account: every row, device, event and alarm of this person's index. */
  async deleteEverything(): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    // This object may serve the same id again before it is evicted: a person who deletes and signs in again.
    this.createTables();
  }

  /**
   * The Worker as this index acts with it: the deployment's own env on a self-hosted Worker, the bound person's on the
   * hosted one. Null when that person has no token to act with.
   */
  private async actingEnv(): Promise<Env | null> {
    const userId = this.meta("user_id");
    if (!userId) {
      return { ...this.env, GITHUB_RATE: newRateLimitState() };
    }
    try {
      const env = await actingEnvFor(this.env, String(userId));
      return env && { ...env, GITHUB_RATE: newRateLimitState() };
    } catch (error) {
      this.addEvent("token_failed", { error: String(error) });
      return null;
    }
  }

  /** When background reads may go again; null when they may now. */
  private rateLimitedUntil(now: number): number | null {
    const until = this.meta("rate_limited_until");
    return until > now ? until : null;
  }

  /** A backoff this run's answers called for, kept for the next runs and said once in `/events` (`rate_limited`). */
  private noteRateLimit(env: Env): void {
    const backoff = env.GITHUB_RATE?.backoff;
    if (!backoff || backoff.until <= Date.now() || backoff.until <= this.meta("rate_limited_until")) {
      return;
    }
    this.setMeta("rate_limited_until", backoff.until);
    this.addEvent("rate_limited", {
      kind: backoff.kind, until: new Date(backoff.until).toISOString(), remaining: env.GITHUB_RATE?.remaining ?? null,
      limit: env.GITHUB_RATE?.limit ?? null,
    });
  }

  private meta(key: string): number {
    return this.sql.exec<{ value: number }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0]?.value ?? 0;
  }

  private setMeta(key: string, value: number): void {
    this.sql.exec(`INSERT INTO meta (key, value) VALUES (?, ?)
      ON CONFLICT (key) DO UPDATE SET value = excluded.value`, key, value);
  }
}
