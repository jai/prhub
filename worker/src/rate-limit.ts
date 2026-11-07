/**
 * GitHub's rate limits, per token (docs/api.md, "Rate limits"). A hosted person's token shares their 5,000 requests an
 * hour with their own `gh`, PATs and other apps, so the Worker's background reads stop well before the limit:
 *
 * - `low`: under a tenth of the hour (at least 100 requests) is left. Background reads (the poll and webhook marks)
 *   wait for the reset; the person's own requests still go.
 * - `primary`: none left. Nothing goes until the reset.
 * - `secondary`: GitHub said `retry-after`, or answered 429. Nothing goes until then (a minute when it gave no time).
 *
 * `observe` reads each answer. The PR index keeps the result per person, in `/events` (`rate_limited`); each isolate
 * keeps it per token too, so a person's requests stop while GitHub asks them to.
 */

export type RateLimitKind = "low" | "primary" | "secondary";

/** What one run of reads learnt about its token. */
export interface RateLimitState {
  /** GitHub calls made. */
  calls: number;
  remaining: number | null;
  limit: number | null;
  /** When the hour resets, in ms. */
  resetAt: number | null;
  /** The backoff the answers call for, or null. */
  backoff: { kind: RateLimitKind; until: number } | null;
}

export const LOW_SHARE = 0.1;
export const LOW_FLOOR = 100;
export const SECONDARY_DEFAULT_MS = 60_000;
/** Never longer than GitHub's hour, whatever a header says. */
const MAX_BACKOFF_MS = 3_600_000;

export function newRateLimitState(): RateLimitState {
  return { calls: 0, remaining: null, limit: null, resetAt: null, backoff: null };
}

function intHeader(response: Response, name: string): number | null {
  const raw = response.headers.get(name);
  const value = raw === null ? Number.NaN : Number(raw);
  return Number.isInteger(value) && value >= 0 ? value : null;
}

/** The backoff one answer calls for; null when it calls for none. */
export function backoffOf(response: Response, now: number): { kind: RateLimitKind; until: number } | null {
  const remaining = intHeader(response, "x-ratelimit-remaining");
  const limit = intHeader(response, "x-ratelimit-limit");
  const reset = intHeader(response, "x-ratelimit-reset");
  const retryAfter = intHeader(response, "retry-after");
  const resetAt = reset === null ? null : Math.min(reset * 1_000, now + MAX_BACKOFF_MS);
  const isRefused = response.status === 403 || response.status === 429;
  if (isRefused && retryAfter !== null) {
    return { kind: "secondary", until: now + Math.min(retryAfter * 1_000, MAX_BACKOFF_MS) };
  }
  if (isRefused && remaining === 0 && resetAt !== null) {
    return { kind: "primary", until: Math.max(resetAt, now + 1_000) };
  }
  if (response.status === 429) {
    return { kind: "secondary", until: now + SECONDARY_DEFAULT_MS };
  }
  if (remaining !== null && limit !== null && resetAt !== null && resetAt > now
    && remaining < Math.max(LOW_FLOOR, limit * LOW_SHARE)) {
    return { kind: remaining === 0 ? "primary" : "low", until: resetAt };
  }
  return null;
}

/** Counts the call and keeps what the answer says, the later and stricter backoff winning. */
export function observe(state: RateLimitState, response: Response, now: number): void {
  state.calls += 1;
  const remaining = intHeader(response, "x-ratelimit-remaining");
  if (remaining !== null) {
    state.remaining = remaining;
    state.limit = intHeader(response, "x-ratelimit-limit") ?? state.limit;
    const reset = intHeader(response, "x-ratelimit-reset");
    state.resetAt = reset === null ? state.resetAt : reset * 1_000;
  }
  const backoff = backoffOf(response, now);
  if (backoff && (!state.backoff || backoff.until > state.backoff.until)) {
    state.backoff = backoff;
  }
}

/** Whether a backoff stops a request: every kind stops background reads; `low` lets the person's own through. */
export function stops(backoff: { kind: RateLimitKind; until: number } | null, now: number, isBackground: boolean): boolean {
  return backoff !== null && backoff.until > now && (isBackground || backoff.kind !== "low");
}

/** Per isolate, per token key: what GitHub last asked of it. Bounded, so a long-lived isolate cannot grow it forever. */
const held = new Map<string, { kind: RateLimitKind; until: number }>();
const MAX_HELD = 1_000;

export function heldBackoff(key: string, now: number): { kind: RateLimitKind; until: number } | null {
  const backoff = held.get(key);
  if (backoff && backoff.until <= now) {
    held.delete(key);
    return null;
  }
  return backoff ?? null;
}

export function holdBackoff(key: string, backoff: { kind: RateLimitKind; until: number } | null): void {
  if (!backoff) {
    return;
  }
  if (held.size >= MAX_HELD && !held.has(key)) {
    held.delete(held.keys().next().value as string);
  }
  held.set(key, backoff);
}

/** The answer a request gets while its token waits: GitHub's own 429, with the wait. */
export function waitAnswer(until: number, now: number): Response {
  return Response.json({ message: "PRHub is waiting for GitHub's rate limit to reset." }, {
    status: 429, headers: { "retry-after": String(Math.max(1, Math.ceil((until - now) / 1_000))) },
  });
}
