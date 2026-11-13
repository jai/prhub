import { alarmToSet } from "./alarm";
import { claimOf, RECEIPT_KEPT_MS, type WriteClaim, type WriteReceipt } from "./write-receipts";
import { DurableObject } from "cloudflare:workers";
import { alertKey, alertKinds, alertMessage, alertsFor, type HeldStatus } from "./alerts";
import { addMissingColumns } from "./pr-columns";
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
  type ChecksNode, type Detail, detailVersionOf, liveDiff, type OpenRowStatus, type PullRequest, type PullRequestRef,
  readChecks, readPullRequests, type ReviewWeek, type RowStatus, searchListings,
} from "./github";
import type { ReadPullRequest } from "./alerts";
import { patchedRead } from "./check-refresh";
import { createGitHubCacheTable, pruneGitHubCache, sqlCache } from "./github-cache";
import { GitHubFailure, readStates, type StatesResult } from "./pr-states";
import {
  BUSY_WINDOW_MS, createMarkTables, type DueMark, dropMark, dueMarks, finishRead, mark, markedIds, nextDueAt,
  postpone, type Scope, throttledDue,
} from "./marks";
import type { PeopleDecision } from "./policy-people";
import { parseRowStatus, parseStoredTicket, parseStoredTickets } from "./boundary";
import { cachedTickets, createTicketsTable, refreshTickets } from "./ticket-cache";
import { allKeys, lookUpTickets, type Ticket } from "./tickets";
import {
  type CodeHash, type DeviceToken, type Fingerprint, parseRepoFullName, parseSha, prId, type PrId, type RepoFullName,
  type Sha,
} from "./ids";
import { putVersioned, storeDiff } from "./versioned";
import { newRateLimitState } from "./rate-limit";
import { DEFAULT_CONTEXT } from "./key-lines";
import { onSubscription } from "./agent-container";
import { OPEN_LISTS } from "./vocab";
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

/** The push that asks a hosted person to sign in again; the app shows Sign in with GitHub when it opens. */
const SIGN_IN_AGAIN: PushMessage = {
  pushType: "alert", priority: 10, collapseId: "prhub-sign-in", lifetimeSeconds: 7 * 86_400,
  payload: { aps: { alert: { title: "PRHub", body: "Sign in with GitHub again to keep your pull requests up to date." } },
    reason: "signed_out" },
};
const READS_PER_PASS = 5;
/** Checks-only reads one pass makes, in one query GitHub prices at a point (`readChecks`). */
const CHECK_READS_PER_PASS = 25;
/** A failed read tries again this soon, every time: GitHub's outage, or a token being replaced, ends. */
const READ_RETRY_MS = 30_000;

const DIFFS_PER_PASS = 10;
const PUSH_SPACING_MS = 30 * 60_000;
const KEPT_EVENTS = 5_000;
/** An alert's key outlives any re-request worth hushing; a month of them is a few hundred rows. */
const ALERTS_KEPT_MS = 30 * 86_400_000;
const KEY_LINES_PER_PASS = 5;
/** Key lines a pass makes for open PRs not waiting on Jai's review, when the token's hour has room. */
const OTHER_KEY_LINES_PER_PASS = 1;
/** A job that failed, say at a usage limit, goes again after this long, so the list heals without being asked. */
const KEY_LINES_RETRY_MS = 30 * 60_000;
/** Raise it when what a row or detail holds changes shape: every held PR is then read again, once. */
const ROW_SHAPE = 12;
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
  /** The Linear tickets the row shows (`rowTickets`); empty without one Linear has, or without Linear. */
  tickets: Ticket[];
  /** The first of `tickets`, for an app older than them; null without one. */
  ticket: Ticket | null;
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
    createTicketsTable(this.sql);
    createMarkTables(this.sql);
    createGitHubCacheTable(this.sql);
    addMissingColumns(this.sql);
  }

  rows(): { prs: Row[]; synced_at: number } {
    return { prs: this.selectRows(`ORDER BY ${LIST_ORDER}`), synced_at: this.meta("synced_at") };
  }

  /** The rows of `GET /prs`, chosen and ordered by `rest`: one SELECT, so an alert's row is the list's row. */
  private selectRows(rest: string, ...bindings: unknown[]): Row[] {
    const rows = this.sql.exec<Omit<Row, "status" | "ticket" | "tickets">
      & { status: string | null; ticket: string | null; tickets: string | null }>(
      `SELECT repo, number, title, head,
      revision, diff_state AS diff, COALESCE(detail_version, NULLIF(version, ''), updated_at) AS detail, status,
      CASE WHEN key_lines_ready = head THEN ${DEFAULT_CONTEXT} END AS keyLines, ticket, tickets
      FROM pull_requests ${rest}`, ...bindings).toArray();
    return rows.map((row) => ({
      ...row, status: parseRowStatus(row.status), ticket: parseStoredTicket(row.ticket),
      tickets: parseStoredTickets(row.tickets),
    }));
  }

  /**
   * A delivery. A PR no list holds and Jai has no part in is dropped here, so it never costs a GitHub read. The rest
   * are read in full, a burst of them once (`marks.ts`). The person's own write is read soon whatever came before it.
   */
  async mark(repo: RepoFullName, number: number, involved: boolean, isOwnWrite = false): Promise<void> {
    const id = prId(repo, number);
    if (!involved && !this.exists("pull_requests", id)) {
      return;
    }
    if (isOwnWrite) {
      mark(this.sql, { id, repo, number }, "full", Date.now() + BUSY_WINDOW_MS, true);
      await this.ensureAlarm(BUSY_WINDOW_MS);
      return;
    }
    await this.markThrottled([{ id, repo, number }], "full");
  }

  /** A check suite or a status on a commit: only the checks of each held PR at that head are read again. */
  async markHead(repo: RepoFullName, sha: Sha): Promise<void> {
    const held = this.sql.exec<{ id: string; repo: string; number: number }>(
      "SELECT id, repo, number FROM pull_requests WHERE repo = ? AND head = ? AND list <> 'merged'", repo, sha)
      .toArray();
    await this.markThrottled(held.flatMap((row) => refOf(row) ?? []), "checks");
  }

  private async markThrottled(refs: PullRequestRef[], scope: Scope): Promise<void> {
    const now = Date.now();
    let earliest: number | null = null;
    for (const ref of refs) {
      const due = throttledDue(this.sql, ref.id, scope, now);
      mark(this.sql, ref, scope, due);
      earliest = Math.min(earliest ?? due, due);
    }
    if (earliest !== null) {
      await this.ensureAlarm(earliest - now);
    }
  }

  /** A read pass, then the alerts it made ready (`push-gate.ts`), which go even when the pass could not read. */
  override async alarm(): Promise<void> {
    const env = await this.actingEnv();
    await this.readMarked(env);
    await this.sendHeldAlerts(env);
  }

  private async readMarked(env: Env | null): Promise<void> {
    const due = (scope: Scope, limit: number) => dueMarks(this.sql, scope, Date.now(), limit).flatMap((row) => {
      const ref = refOf(row);
      if (!ref) {
        dropMark(this.sql, row.id);
      }
      return ref ? [{ ...row, ...ref }] : [];
    });
    const dirty = due("full", READS_PER_PASS);
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
        const tickets = (keys: string[]) => cachedTickets(this.sql, keys, Date.now(), (stale) => lookUpTickets(stale, env));
        read = await readPullRequests(dirty, env, asked, tickets, sqlCache(this.sql));
      } catch (error) {
        await this.readFailed(env, error);
        return;
      }
      for (const marked of dirty) {
        const pr = read.get(marked.id);
        if (pr?.status && !this.isFullFor(marked.id)) {
          const listed: Listed = { ...pr, status: pr.status };
          this.holdAlertsOn(listed);
          await this.store(listed, env);
        } else if (pr?.status) {
          this.addEvent("limit_reached", { limit: LimitName.IndexedPullRequestsMax, pr: marked.id });
        } else {
          this.remove(marked.id);
        }
        finishRead(this.sql, "full", marked, Date.now());
      }
    }
    await this.readMarkedChecks(env, due("checks", CHECK_READS_PER_PASS));
    await this.storeDiffs(env);
    await this.queueKeyLines(env);
    this.noteRateLimit(env);
    const next = this.exists("pending") ? Date.now() : nextDueAt(this.sql);
    if (next !== null) {
      await this.ctx.storage.setAlarm(this.rateLimitedUntil(Date.now()) ?? Math.max(next, Date.now() + 250));
    }
  }

  /** Not thrown: Cloudflare would retry it later and later, and new work would wait behind that retry. */
  private async readFailed(env: Env, error: unknown): Promise<void> {
    this.addEvent("read_failed", { error: String(error) });
    this.noteRateLimit(env);
    await this.ctx.storage.setAlarm(this.rateLimitedUntil(Date.now()) ?? Date.now() + READ_RETRY_MS);
  }

  /**
   * The checks of PRs a check suite or a status marked, all in one query, laid over what the index holds
   * (`check-refresh.ts`). A PR that needs more is marked for a full read, within its window. One GitHub refused is
   * left until its next delivery or the poll; when the whole query fails, every mark waits `READ_RETRY_MS`.
   */
  private async readMarkedChecks(env: Env, marks: (DueMark & PullRequestRef)[]): Promise<void> {
    if (marks.length === 0) {
      return;
    }
    let read: Awaited<ReturnType<typeof readChecks>>;
    try {
      read = await readChecks(marks, env);
    } catch (error) {
      this.addEvent("read_failed", { scope: "checks", error: String(error) });
      postpone(this.sql, "checks", marks.map(({ id }) => id), Date.now() + READ_RETRY_MS);
      return;
    }
    for (const checks of marks) {
      const node = read.get(checks.id);
      if (node === "error") {
        this.addEvent("read_failed", { scope: "checks", pr: checks.id });
      } else if ((node ? await this.storeChecks(checks.id, node, env) : "full") === "full") {
        mark(this.sql, checks, "full", throttledDue(this.sql, checks.id, "full", Date.now()));
      }
      finishRead(this.sql, "checks", checks, Date.now());
    }
  }

  /**
   * The held row and detail with fresh checks. `full`: it needs a full read instead. `skip`: nothing to do, as the row
   * went or is merged.
   */
  private async storeChecks(id: PrId, node: ChecksNode, env: Env): Promise<"stored" | "full" | "skip"> {
    const row = this.sql.exec<{ repo: string; number: number; title: string; head: string; updated_at: string;
      status: string | null; detail_version: string | null; people: string | null; people_at: number | null }>(
      `SELECT repo, number, title, head, updated_at, status, detail_version, people, people_at FROM pull_requests
      WHERE id = ?`, id).toArray()[0];
    const status = parseRowStatus(row?.status ?? null);
    const repo = parseRepoFullName(row?.repo);
    if (!row || !repo || status?.list === "merged") {
      return "skip";
    }
    if (!status || row.people === null || row.people_at === null || row.detail_version === null
      || this.meta("row_shape") < ROW_SHAPE) {
      return "full";
    }
    const stored = await env.DIFFS.get(scopedKey(env, detailKey(row.repo, row.number, row.detail_version)));
    const detail = stored ? await stored.json<Detail>().catch(() => null) : null;
    const people = JSON.parse(row.people) as PeopleDecision | null;
    const patched = detail && patchedRead({
      head: row.head, updatedAt: row.updated_at, status, detail, people, peopleAt: row.people_at,
    }, node, Date.now());
    if (!patched) {
      return "full";
    }
    this.holdAlerts(status, {
      repo, number: row.number, head: row.head, title: row.title, list: patched.status.list,
      review: patched.status.review, requestedAt: patched.status.list === "review" ? patched.status.requestedAt : null,
    });
    const detailVersion = await detailVersionOf(patched);
    if (detailVersion === row.detail_version) {
      return "stored";
    }
    await putVersioned(env.DIFFS, scopedKey(env, detailKey(row.repo, row.number, detailVersion)), detailVersion,
      JSON.stringify(patched.detail), "application/json");
    this.sql.exec(`UPDATE pull_requests SET version = ?, detail_version = ?, status = ?, changed_at = ? WHERE id = ?
      AND head = ?`, patched.version, detailVersion, JSON.stringify(patched.status), Date.now(), id, row.head);
    this.setMeta("changed_at", Date.now());
    return "stored";
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
    await this.refreshTicketsOf(env, now);
    this.sql.exec("DELETE FROM alerts WHERE at < ?", now - ALERTS_KEPT_MS);
    pruneReviewedKeyLines(this.sql, now);
    pruneGitHubCache(this.sql, now);
    await this.sweepIfDue(env, now);
    await this.pushIfDue(now);
  }

  /** A ticket that moved on in Linear: its PRs are read again, so the row and the detail say the same. */
  private async refreshTicketsOf(env: Env, now: number): Promise<void> {
    if (!isSet(env.LINEAR_API_KEY)) {
      return;
    }
    const changed = await refreshTickets(this.sql, now, (keys) => lookUpTickets(keys, env));
    for (const row of changed) {
      const ref = refOf(row);
      if (ref) {
        this.markDirty(ref.id, ref.repo, ref.number);
      }
    }
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
    const now = Date.now();
    const held = this.sql.exec<{ id: string; repo: string; number: number; version: string; status: string | null }>(
      "SELECT id, repo, number, version, status FROM pull_requests").toArray();
    const isCurrentShape = this.meta("row_shape") >= ROW_SHAPE;
    const versions = new Map<string, string | null>(
      held.map((row) => [row.id, row.status && isCurrentShape ? row.version : null]));
    this.setMeta("row_shape", ROW_SHAPE);
    const updatedOf = (version: string | null | undefined) => version?.slice(0, version.indexOf(".")) ?? null;
    for (const { id, repo, number, version, reviewedOnly } of listings.values()) {
      const heldVersion = versions.get(id);
      if (heldVersion === version || (reviewedOnly && !versions.has(id))) {
        continue;
      }
      // The same `updatedAt` with another checks rollup: only checks moved, and a checks-only read will do.
      const scope = heldVersion && updatedOf(heldVersion) === updatedOf(version) ? "checks" : "full";
      mark(this.sql, { id, repo, number }, scope, now);
    }
    for (const row of held) {
      const ref = refOf(row);
      if (ref && !listings.has(ref.id)) {
        this.markDirty(ref.id, ref.repo, ref.number);
      }
    }
    const next = nextDueAt(this.sql);
    if (next !== null || this.exists("pending")) {
      await this.ensureAlarm(Math.max(0, (next ?? now) - now));
    }
  }

  /**
   * The alerts a fresh read calls for, each claimed in storage, so the same PR and head never alerts twice
   * (`alerts.ts`), and held until its PR's files are stored (`push-gate.ts`). Read before `store` overwrites what was
   * held.
   */
  private holdAlertsOn(pr: Listed): void {
    const heldRow = this.sql.exec<{ status: string | null }>(
      "SELECT status FROM pull_requests WHERE id = ?", prId(pr.repo, pr.number)).toArray()[0];
    this.holdAlerts(parseRowStatus(heldRow?.status ?? null), { ...pr, list: pr.status.list, review: pr.status.review });
  }

  private holdAlerts(held: HeldStatus, read: ReadPullRequest): void {
    const kinds = alertKinds(this.env);
    if (kinds.size === 0) {
      return;
    }
    const now = Date.now();
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
    const makesKeyLines = env !== null && onSubscription(env);
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

  /**
   * `POST /prs/states` (pr-states.ts), read here so `.policy.yml` texts and memberships come from this index's own
   * cache: a repeat from any isolate is a hit or a free 304, not a paid REST call. Says the GitHub calls it made.
   */
  async states(refs: PrId[], week: ReviewWeek | null): Promise<StatesResult> {
    const env = await this.actingEnv();
    if (!env) {
      return { failure: { code: "signed_out", message: "signed out of GitHub" }, githubCalls: 0 };
    }
    const rate = env.GITHUB_RATE ?? newRateLimitState();
    const counted = { ...env, GITHUB_RATE: rate };
    try {
      return { answer: await readStates(refs, week, counted, sqlCache(this.sql)), githubCalls: rate.calls };
    } catch (failure) {
      if (failure instanceof GitHubFailure) {
        return { failure: { code: failure.code, message: failure.message }, githubCalls: rate.calls };
      }
      throw failure;
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
    for (const row of markedIds(this.sql).filter((one) => names.has(one.repo.toLowerCase()))) {
      dropMark(this.sql, row.id);
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

  private exists(what: "pull_requests" | "pending", id?: string): boolean {
    const query = {
      pull_requests: "SELECT 1 FROM pull_requests WHERE id = ?",
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

  /** A full read due now: the poll, Linear or a carried index found the PR behind. */
  private markDirty(id: PrId, repo: RepoFullName, number: number): void {
    mark(this.sql, { id, repo, number }, "full", Date.now());
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
        detail_version, status, changed_at, ticket, ticket_keys, tickets, people, people_at, diff_state, diff_tried_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0)
      ON CONFLICT (id) DO UPDATE SET title = excluded.title, head = excluded.head, list = excluded.list,
        updated_at = excluded.updated_at, version = excluded.version, detail_version = excluded.detail_version,
        status = excluded.status, changed_at = excluded.changed_at, ticket = excluded.ticket,
        ticket_keys = excluded.ticket_keys, tickets = excluded.tickets, people = excluded.people,
        people_at = excluded.people_at,
        diff_state = CASE WHEN revision <> excluded.revision THEN 'pending' ELSE diff_state END,
        diff_tried_at = CASE WHEN revision <> excluded.revision THEN 0 ELSE diff_tried_at END,
        revision = excluded.revision`,
    id, pr.repo, pr.number, pr.title, pr.head, pr.revision, pr.status.list, pr.updatedAt, pr.version, detailVersion,
    JSON.stringify(pr.status), Date.now(), pr.ticket && JSON.stringify(pr.ticket),
    JSON.stringify(allKeys(pr.ticketKeys)), JSON.stringify(pr.tickets), JSON.stringify(pr.people),
    Date.now());
    if (held?.detail_version !== detailVersion) {
      this.setMeta("changed_at", Date.now());
    }
  }

  /**
   * One job per new head of every open PR on Jai's lists, those waiting on his review first, only on the subscription: on
   * an API key every PR nobody opens would cost money. `AiJobs` runs it, so this mirror never waits on a model.
   */
  private async queueKeyLines(env: Env): Promise<void> {
    if (!onSubscription(env)) {
      return;
    }
    // Key lines read every changed file from GitHub. Those waiting on Jai's review go five a pass; the rest, one a pass
    // and only while the token's hour is not low, so making them never starves the list or his other tools.
    const spare = this.rateLimitedUntil(Date.now()) === null;
    let others = spare ? OTHER_KEY_LINES_PER_PASS : 0;
    const lists = OPEN_LISTS.map((list) => `'${list}'`).join(", ");
    const rows = this.sql.exec<{ id: string; repo: string; number: number; head: string; list: string }>(`SELECT id,
      repo, number, head, list FROM pull_requests WHERE list IN (${lists}) AND diff_state = 'ready'
        AND (COALESCE(key_lines_queued, '') <> head
          OR (COALESCE(key_lines_ready, '') <> head AND COALESCE(key_lines_tried_at, 0) < ?))
      ORDER BY list = 'review' DESC LIMIT ?`, Date.now() - KEY_LINES_RETRY_MS, KEY_LINES_PER_PASS).toArray();
    const due = rows.filter((row) => row.list === "review" || others-- > 0);
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
