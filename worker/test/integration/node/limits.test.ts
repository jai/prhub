// The limits: their config (`limits.ts`), the counter (`limit-counter.ts`) on real SQLite, the routes' side
// (`limit-enforcement.ts`), retention (`retention.ts`), and what the hosted account does with lifetimes and key rotation.
import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { prId, repoOf } from "../../../src/ids.ts";
import { AccountCore } from "../../../src/account-core.ts";
import type { Env } from "../../../src/env.ts";
import {
  consumeLimits,
  createLimitHitsTable,
  type LimitCheck,
  lastExpiry,
  type LimitSql,
} from "../../../src/limit-counter.ts";
import {
  pairingLimitAnswer,
  personLimitAnswer,
  reportedLimitsOf,
} from "../../../src/limit-enforcement.ts";
import {
  type Count,
  LimitName,
  limitsOf,
  type Milliseconds,
  parseLimits,
  rateWindowOf,
  WorkerMode,
} from "../../../src/limits.ts";
import { sweepClosedPullRequests } from "../../../src/retention.ts";
import { keyIdOf, parseKeyring } from "../../../src/token-crypto.ts";
import {
  APP,
  APP_VERIFIER,
  bearer,
  callback,
  hostedWorld,
  keyOf,
  MapStore,
  signIn,
  startSignIn,
} from "../../support/hosted-world.ts";
import { closeMemorySql, memorySql } from "../../support/memory-sql.ts";

afterEach(closeMemorySql);

const MINUTE = 60_000;
const NOW = Date.parse("2026-11-07T00:00:00Z");
const window = (count: number, windowMs: number) => ({
  count: count as Count,
  windowMs: windowMs as Milliseconds,
});

// --- Counting -------------------------------------------------------------------------------------------------------

function counter(): LimitSql {
  const sql = memorySql();
  createLimitHitsTable(sql);
  return sql;
}

const writes: LimitCheck[] = [
  { name: LimitName.WritesPerMinute, window: window(2, MINUTE) },
  { name: LimitName.WritesPerHour, window: window(3, 60 * MINUTE) },
];

test("a limit lets its count through in a window, then says which limit and when it frees up", () => {
  const sql = counter();
  assert.deepEqual(consumeLimits(sql, writes, "", "a", NOW), { allowed: true });
  assert.deepEqual(consumeLimits(sql, writes, "", "b", NOW + 10_000), { allowed: true });
  assert.deepEqual(consumeLimits(sql, writes, "", "c", NOW + 20_000), {
    allowed: false,
    name: LimitName.WritesPerMinute,
    retryAfterMs: 40_000,
  });
  assert.deepEqual(consumeLimits(sql, writes, "", "c", NOW + MINUTE + 1), { allowed: true });
  assert.deepEqual(consumeLimits(sql, writes, "", "d", NOW + 2 * MINUTE), {
    allowed: false,
    name: LimitName.WritesPerHour,
    retryAfterMs: 58 * MINUTE,
  });
});

test("a retried request with the same key is counted once, and passes a limit it already passed", () => {
  const sql = counter();
  const one = [writes[0]];
  assert.equal(consumeLimits(sql, one, "", "write:acme/api#7:ref-1", NOW).allowed, true);
  assert.equal(consumeLimits(sql, one, "", "write:acme/api#7:ref-2", NOW).allowed, true);
  for (let retry = 0; retry < 5; retry += 1) {
    assert.equal(consumeLimits(sql, one, "", "write:acme/api#7:ref-1", NOW + retry).allowed, true);
  }
  assert.equal(consumeLimits(sql, one, "", "write:acme/api#7:ref-3", NOW).allowed, false);
});

test("a refused request counts toward no limit, and each subject has its own count", () => {
  const sql = counter();
  consumeLimits(sql, [writes[0]], "", "a", NOW);
  consumeLimits(sql, [writes[0]], "", "b", NOW);
  assert.equal(consumeLimits(sql, writes, "", "c", NOW).allowed, false);
  const [{ hits }] = sql
    .exec<{ hits: number }>(
      "SELECT count(*) AS hits FROM limit_hits WHERE name = ?",
      LimitName.WritesPerHour,
    )
    .toArray();
  assert.equal(hits, 0, "the hour did not count the refused write");
  assert.equal(consumeLimits(sql, [writes[0]], "ip:x", "a", NOW).allowed, true);
});

test("expired counts are deleted, and the last expiry says when an IP's object can go", () => {
  const sql = counter();
  consumeLimits(sql, writes, "", "a", NOW);
  assert.equal(lastExpiry(sql), NOW + 60 * MINUTE);
  consumeLimits(sql, [writes[0]], "", "b", NOW + 61 * MINUTE);
  const [{ rows }] = sql
    .exec<{ rows: number }>("SELECT count(*) AS rows FROM limit_hits")
    .toArray();
  assert.equal(rows, 1);
});

// --- The routes' side -----------------------------------------------------------------------------------------------

/** A Worker env whose `PrIndex` counts on real SQLite and keeps what it records. */
function countingEnv(vars: Partial<Env>) {
  const sql = counter();
  const recorded: { kind: string; detail: unknown }[] = [];
  const index = {
    consumeLimits: (checks: LimitCheck[], subject: string, key: string, now: number) =>
      consumeLimits(sql, checks, subject, key, now),
    record: (kind: string, detail: unknown) => {
      recorded.push({ kind, detail });
    },
  };
  const namespace = { idFromName: (name: string) => name, get: () => index };
  return { env: { PR_INDEX: namespace, ...vars } as unknown as Env, recorded };
}

test("past a person's write limit the answer is 429 limit_reached with the limit and retry_after", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: NOW });
  const { env } = countingEnv({ LIMIT_WRITES_PER_MINUTE: "1" });
  const names = [LimitName.WritesPerMinute, LimitName.WritesPerHour];
  assert.equal(await personLimitAnswer(env, names, "write:acme/api#7:one"), null);
  assert.equal(
    await personLimitAnswer(env, names, "write:acme/api#7:one"),
    null,
    "the outbox's retry",
  );
  const refused = await personLimitAnswer(env, names, "write:acme/api#7:two");
  assert.equal(refused?.status, 429);
  assert.equal(Number(refused?.headers.get("Retry-After")) > 0, true);
  const { error } = (await refused?.json()) as {
    error: { code: string; limit: string; retry_after: number };
  };
  assert.equal(error.code, "limit_reached");
  assert.equal(error.limit, "writes_per_minute");
  assert.equal(error.retry_after > 0 && error.retry_after <= 60, true);
});

test("a self-hosted Worker counts pairing attempts per IP", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: NOW });
  const { env } = countingEnv({ LIMIT_PAIRING_ATTEMPTS_PER_IP_PER_HOUR: "2" });
  const pair = (ip: string) =>
    new Request("https://worker.example/device/pair", { headers: { "CF-Connecting-IP": ip } });
  assert.equal(await pairingLimitAnswer(pair("198.51.100.1"), env), null);
  assert.equal(await pairingLimitAnswer(pair("198.51.100.1"), env), null);
  assert.equal((await pairingLimitAnswer(pair("198.51.100.1"), env))?.status, 429);
  assert.equal(await pairingLimitAnswer(pair("198.51.100.2"), env), null);
});

test("bad limit config goes to /events once per isolate, as limits_config_error", () => {
  const { env, recorded } = countingEnv({ LIMIT_WRITES_PER_MINUTE: "lots" });
  const waited: Promise<unknown>[] = [];
  const waitUntil = (promise: Promise<unknown>) => waited.push(promise);
  reportedLimitsOf(env, waitUntil);
  reportedLimitsOf(env, waitUntil);
  assert.deepEqual(
    recorded.map(({ kind }) => kind),
    ["limits_config_error"],
  );
  assert.equal(
    rateWindowOf(limitsOf(env), LimitName.WritesPerMinute),
    null,
    "the self-hosted default serves",
  );
});

// --- Retention ------------------------------------------------------------------------------------------------------

test("the sweep deletes a closed PR's objects once the newest is past retention, and keeps open PRs'", async () => {
  const day = 86_400_000;
  const objects = new Map<string, Date>([
    ["users/1/acme/api/7/r1.diff", new Date(NOW - 40 * day)],
    ["users/1/acme/api/7/detail/v1.json", new Date(NOW - 40 * day)],
    ["users/1/ai/acme/api/7/head/rewrite.json", new Date(NOW - 35 * day)],
    ["users/1/acme/api/8/r1.diff", new Date(NOW - 40 * day)],
    ["users/1/acme/api/8/detail/v2.json", new Date(NOW - 2 * day)],
    ["users/1/acme/api/9/r1.diff", new Date(NOW - 90 * day)],
    ["users/1/repos/index.json", new Date(NOW - 90 * day)],
  ]);
  const bucket = {
    list: async ({ cursor }: { cursor?: string }) => {
      const keys = [...objects.keys()].sort();
      const start = cursor ? Number(cursor) : 0;
      const page = keys.slice(start, start + 2);
      const truncated = start + 2 < keys.length;
      return {
        objects: page.map((key) => ({ key, uploaded: objects.get(key) as Date })),
        truncated,
        cursor: truncated ? String(start + 2) : undefined,
      };
    },
    delete: async (keys: string | string[]) => {
      for (const key of [keys].flat()) {
        objects.delete(key);
      }
    },
  } as unknown as Pick<R2Bucket, "list" | "delete">;
  const deleted = await sweepClosedPullRequests(
    bucket,
    "users/1/",
    (id) => id === prId(repoOf("acme/api"), 9),
    NOW - 30 * day,
  );
  assert.equal(deleted, 3);
  assert.deepEqual([...objects.keys()].sort(), [
    "users/1/acme/api/8/detail/v2.json",
    "users/1/acme/api/8/r1.diff",
    "users/1/acme/api/9/r1.diff",
    "users/1/repos/index.json",
  ]);
  assert.equal(
    await sweepClosedPullRequests(
      bucket,
      "users/1/",
      (id) => id === prId(repoOf("acme/api"), 9),
      NOW - 30 * day,
    ),
    0,
    "a second run finds nothing left",
  );
});

// --- The account ----------------------------------------------------------------------------------------------------

const fingerprintOf = async (secret: string) =>
  Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret))).toString(
    "hex",
  );

test("a session lives session_lifetime_days, and a person keeps sessions_max of them", async () => {
  const world = hostedWorld({ LIMIT_SESSION_LIFETIME_DAYS: "2", LIMIT_SESSIONS_MAX: "2" });
  const first = await signIn(world);
  world.clock.now += 86_400_000;
  const second = await signIn(world);
  const third = await signIn(world);
  const account = world.accounts.get("4242") as AccountCore;
  assert.equal(
    await account.session(await fingerprintOf(first)),
    null,
    "pushed out by sessions_max",
  );
  assert.ok(await account.session(await fingerprintOf(second)));
  world.clock.now += 2 * 86_400_000;
  assert.equal(await account.session(await fingerprintOf(third)), null, "past its lifetime");
  assert.equal(
    (await world.route("/auth/signout", { method: "POST", ...bearer(third) })).status,
    401,
  );
});

test("the pending sign-in and the one-time code live as long as their limits say", async () => {
  const world = hostedWorld({ LIMIT_SIGN_IN_CODE_MINUTES: "1", LIMIT_SIGN_IN_MINUTES: "2" });
  const authorize = await startSignIn(world);
  const [pending] = world.pending.values();
  assert.equal(pending.expires_at, world.clock.now + 2 * MINUTE);
  const done = await callback(world, {
    code: "gh-code",
    state: authorize.searchParams.get("state") ?? "",
  });
  world.clock.now += MINUTE + 1;
  const finish = await world.route("/auth/github/finish", {
    method: "POST",
    body: JSON.stringify({ code: done.searchParams.get("code"), code_verifier: APP_VERIFIER }),
  });
  assert.equal(finish.status, 401, "the code outlived sign_in_code_minutes");
});

test("after a key rotation the sweep seals every value again with the new key and reports what moved", async () => {
  const store = new MapStore();
  let raw = `k1:${keyOf(1)}`;
  const account = new AccountCore({
    store,
    keyring: () => parseKeyring(raw),
    app: APP,
    fetch: async () => new Response(null, { status: 500 }),
    now: () => NOW,
    limits: parseLimits({}, WorkerMode.Hosted),
    onSignedOut: async () => {},
  });
  await account.signIn(
    { id: 4242, login: "octocat" },
    {
      access_token: "ghu_old",
      expires_in: 28_800,
      refresh_token: "ghr_old",
      refresh_token_expires_in: 15_897_600,
    } as never,
    "c".repeat(43),
  );
  await account.setAnthropicKey("sk-test-0123456789abcdef", null);
  assert.deepEqual(await account.resealStale(), { current: "k1", resealed: [], stale: [] });

  raw = `k2:${keyOf(2)},k1:${keyOf(1)}`;
  assert.deepEqual(await account.resealStale(), {
    current: "k2",
    resealed: ["access", "refresh", "anthropic"],
    stale: [],
  });
  const held = await store.get<{ tokens: { access: string; refresh: string } }>("account");
  assert.equal(keyIdOf(held?.tokens.access ?? ""), "k2");
  assert.equal(keyIdOf(held?.tokens.refresh ?? ""), "k2");

  raw = `k3:${keyOf(3)}`;
  assert.deepEqual(
    await account.resealStale(),
    {
      current: "k3",
      resealed: [],
      stale: ["access", "refresh", "anthropic"],
    },
    "a key dropped too soon leaves values no key opens, and says so",
  );
});
