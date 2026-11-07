/**
 * The routes' side of the limits (`limits.ts`): a request counted against its person's own `PrIndex`, or, on a
 * self-hosted Worker's pairing, against its IP there. Past a limit the route answers `429 limit_reached`.
 */
import { type Env, prIndex } from "./env.ts";
import { LimitName, limitReachedAnswer, limitsOf, type Limits, rateWindowOf, type RateLimitName } from "./limits.ts";
import type { LimitCheck } from "./limit-counter.ts";
import { sha256Hex } from "./pairing.ts";
import { randomToken } from "./token-crypto.ts";

function checksOf(limits: Limits, names: readonly RateLimitName[]): LimitCheck[] {
  return names.flatMap((name) => {
    const window = rateWindowOf(limits, name);
    return window ? [{ name, window }] : [];
  });
}

async function consume(env: Env, names: readonly RateLimitName[], subject: string, key: string):
Promise<Response | null> {
  const checks = checksOf(limitsOf(env), names);
  if (checks.length === 0) {
    return null;
  }
  const decision = await prIndex(env).consumeLimits(checks, subject, key, Date.now());
  return decision.allowed ? null : limitReachedAnswer(decision.name, decision.retryAfterMs);
}

/**
 * One request of the person `env` acts for, against `names`; null when every one has room. `key` names the request,
 * so a repeat of it (the same `client_ref`, or the same AI job) is not counted again; null counts every request.
 */
export function personLimitAnswer(env: Env, names: readonly RateLimitName[], key: string | null):
Promise<Response | null> {
  return consume(env, names, "", key ?? randomToken());
}

/** `POST /device/pair` on a self-hosted Worker, counted per IP (`pairing_attempts_per_ip_per_hour`). */
export async function pairingLimitAnswer(request: Request, env: Env): Promise<Response | null> {
  const ipHash = await sha256Hex(request.headers.get("CF-Connecting-IP") ?? "unknown");
  return consume(env, [LimitName.PairingAttemptsPerIpPerHour], `ip:${ipHash}`, randomToken());
}

/** The vars whose problems are in `/events` already from this isolate. */
let reportedLimits: string | null = null;

/** The Worker's limits; their config problems go to `/events` (`limits_config_error`) once per isolate and per value. */
export function reportedLimitsOf(env: Env, waitUntil: (promise: Promise<unknown>) => void): Limits {
  const limits = limitsOf(env);
  const key = JSON.stringify(limits.problems);
  if (limits.problems.length > 0 && reportedLimits !== key) {
    reportedLimits = key;
    console.error("limits config problems", limits.problems);
    waitUntil(prIndex(env).record("limits_config_error", { problems: limits.problems }));
  }
  return limits;
}
