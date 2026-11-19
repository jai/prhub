// The limit counter (`limit-counter.ts`) on real SQLite, and the routes' side (`limit-enforcement.ts`) counting on it.
import assert from "node:assert/strict";
import { test, vi } from "vitest";
import type { Env } from "../../../src/env.ts";
import {
  consumeLimits,
  createLimitHitsTable,
  type LimitCheck,
  lastExpiry,
  type LimitSql,
} from "../../../src/limit-counter.ts";
import { pairingLimitAnswer, personLimitAnswer } from "../../../src/limit-enforcement.ts";
import { type Count, LimitName, type Milliseconds } from "../../../src/limits.ts";
import { memorySql } from "../../support/memory-sql.ts";

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

test("past a person's write limit the answer is 429 limit_reached with the limit and retry_after", async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: NOW });
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

test("a self-hosted Worker counts pairing attempts per IP", async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: NOW });
  const { env } = countingEnv({ LIMIT_PAIRING_ATTEMPTS_PER_IP_PER_HOUR: "2" });
  const pair = (ip: string) =>
    new Request("https://worker.example/device/pair", { headers: { "CF-Connecting-IP": ip } });
  assert.equal(await pairingLimitAnswer(pair("198.51.100.1"), env), null);
  assert.equal(await pairingLimitAnswer(pair("198.51.100.1"), env), null);
  assert.equal((await pairingLimitAnswer(pair("198.51.100.1"), env))?.status, 429);
  assert.equal(await pairingLimitAnswer(pair("198.51.100.2"), env), null);
});
