// Per-key counters: minute buckets for the last hour and hour buckets for the last day. The minute limit counts the
// current clock minute; the hour limit slides over the last sixty minute buckets.

export const MINUTE_LIMIT = 60;
export const HOUR_LIMIT = 600;

/** `[bucket index, count]` pairs; a minute index is `floor(seconds / 60)`, an hour index `floor(seconds / 3600)`. */
export interface Counters {
  minutes: [number, number][];
  hours: [number, number][];
}

export type ConsumeResult = { ok: true; counters: Counters } | { ok: false; retryAfter: number };

export function emptyCounters(): Counters {
  return { minutes: [], hours: [] };
}

/** Counts one push at `nowSeconds`, or says how long until the key may send again. */
export function consume(counters: Counters, nowSeconds: number): ConsumeResult {
  const minute = Math.floor(nowSeconds / 60);
  const hour = Math.floor(nowSeconds / 3600);
  const minutes = counters.minutes.filter(([index]) => index > minute - 60).sort((a, b) => a[0] - b[0]);
  const hours = counters.hours.filter(([index]) => index > hour - 24);

  const thisMinute = minutes.find(([index]) => index === minute)?.[1] ?? 0;
  if (thisMinute >= MINUTE_LIMIT) return { ok: false, retryAfter: Math.max(1, (minute + 1) * 60 - nowSeconds) };

  let lastHour = minutes.reduce((sum, [, count]) => sum + count, 0);
  if (lastHour >= HOUR_LIMIT) {
    // Wait until enough of the oldest buckets leave the window to bring the count under the limit.
    for (const [index, count] of minutes) {
      lastHour -= count;
      if (lastHour < HOUR_LIMIT) return { ok: false, retryAfter: Math.max(1, (index + 60) * 60 - nowSeconds) };
    }
  }

  return { ok: true, counters: { minutes: bump(minutes, minute), hours: bump(hours, hour) } };
}

/** Pushes counted in the hour buckets of the last 24 hours. */
export function sentLastDay(counters: Counters, nowSeconds: number): number {
  const hour = Math.floor(nowSeconds / 3600);
  return counters.hours.filter(([index]) => index > hour - 24).reduce((sum, [, count]) => sum + count, 0);
}

function bump(buckets: [number, number][], index: number): [number, number][] {
  const found = buckets.some(([existing]) => existing === index);
  if (!found) return [...buckets, [index, 1]];
  return buckets.map(([existing, count]) => [existing, existing === index ? count + 1 : count]);
}
