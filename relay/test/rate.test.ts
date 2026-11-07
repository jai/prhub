import assert from "node:assert/strict";
import { test } from "node:test";
import { type Counters, consume, emptyCounters, HOUR_LIMIT, MINUTE_LIMIT, sentLastDay } from "../src/rate.ts";

function sendMany(counters: Counters, nowSeconds: number, count: number): Counters {
  for (let i = 0; i < count; i++) {
    const result = consume(counters, nowSeconds);
    assert.ok(result.ok, `push ${i} at ${nowSeconds} was refused`);
    counters = result.counters;
  }
  return counters;
}

const start = 1_800_000_000 - (1_800_000_000 % 3600); // on the hour

test("60 in a minute pass, the 61st waits for the next minute", () => {
  const counters = sendMany(emptyCounters(), start + 15, MINUTE_LIMIT);
  assert.deepEqual(consume(counters, start + 15), { ok: false, retryAfter: 45 });
  assert.ok(consume(counters, start + 60).ok);
});

test("600 in an hour pass, the 601st waits until the oldest minute leaves the window", () => {
  let counters = emptyCounters();
  for (let minute = 0; minute < 10; minute++) counters = sendMany(counters, start + minute * 60, 60);
  const later = start + 30 * 60 + 10;
  assert.deepEqual(consume(counters, later), { ok: false, retryAfter: start + 3600 - later });
  assert.ok(consume(counters, start + 3600).ok);
});

test("old buckets are dropped and a day's total is kept by the hour", () => {
  let counters = sendMany(emptyCounters(), start, 5);
  counters = sendMany(counters, start + 5 * 3600, 3);
  assert.equal(sentLastDay(counters, start + 5 * 3600), 8);
  assert.equal(sentLastDay(counters, start + 24 * 3600), 3);
  const next = consume(counters, start + 5 * 3600 + 1);
  assert.ok(next.ok);
  assert.ok(next.counters.minutes.every(([index]) => index > Math.floor((start + 5 * 3600) / 60) - 60));
  assert.ok(HOUR_LIMIT > MINUTE_LIMIT);
});
