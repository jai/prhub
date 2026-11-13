import type { Env } from "./env.ts";

/** One TestFlight build of PRHub: `CFBundleShortVersionString` and `CFBundleVersion`. */
export interface AppBuild {
  version: string;
  build: string;
}

/** `GET /device/config`'s `app_latest`: the newest build each TestFlight group can install. Either may be absent. */
export interface AppLatest {
  internal?: AppBuild;
  public?: AppBuild;
}

/** Where `.github/workflows/internal-testflight.yml` publishes it (release/app-latest.mjs). `APP_LATEST_URL` overrides. */
export const APP_LATEST_URL = "https://raw.githubusercontent.com/jai/prhub/ci/app-latest/app-latest.json";

const FRESH_MS = 10 * 60_000;
const TIMEOUT_MS = 1_500;
const VERSION = /^\d+(\.\d+){0,3}$/;
const BUILD = /^\d{1,9}$/;

let kept: { url: string; at: number; value: AppLatest | undefined } | null = null;

function buildOf(value: unknown): AppBuild | undefined {
  if (typeof value !== "object" || value === null) {
    return undefined;
  }
  const { version, build } = value as Record<string, unknown>;
  return typeof version === "string" && VERSION.test(version) && typeof build === "string" && BUILD.test(build)
    ? { version, build }
    : undefined;
}

/** The published file's groups that are well formed; undefined when neither is. */
export function parseAppLatest(value: unknown): AppLatest | undefined {
  if (typeof value !== "object" || value === null) {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  const internal = buildOf(record.internal);
  const published = buildOf(record.public);
  if (!internal && !published) {
    return undefined;
  }
  return { ...(internal ? { internal } : {}), ...(published ? { public: published } : {}) };
}

/**
 * The newest TestFlight builds, kept 10 minutes per isolate and by Cloudflare's cache. A read that fails or takes
 * longer than 1.5 s answers what the isolate last kept, or nothing, and is tried again a minute later.
 */
export async function appLatest(env: Pick<Env, "APP_LATEST_URL">, fetchImpl: typeof fetch = fetch,
  now = Date.now()): Promise<AppLatest | undefined> {
  const url = env.APP_LATEST_URL?.trim() || APP_LATEST_URL;
  if (url === "off") {
    return undefined;
  }
  if (kept?.url === url && now - kept.at < FRESH_MS) {
    return kept.value;
  }
  try {
    const response = await fetchImpl(url, {
      signal: AbortSignal.timeout(TIMEOUT_MS),
      cf: { cacheTtl: FRESH_MS / 1000, cacheEverything: true },
    } as RequestInit);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const value = parseAppLatest(await response.json());
    kept = { url, at: now, value };
    return value;
  } catch {
    // Asked again in a minute, not on every config read meanwhile.
    const value = kept?.url === url ? kept.value : undefined;
    kept = { url, at: now - FRESH_MS + 60_000, value };
    return value;
  }
}

/** Tests only: forget what the isolate kept. */
export function forgetAppLatest(): void {
  kept = null;
}
