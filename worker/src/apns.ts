import { type Env, isSet } from "./env.ts";

export const APNS_HOSTS = ["production", "sandbox"] as const;
export type ApnsHost = typeof APNS_HOSTS[number];

const HOSTS: Record<ApnsHost, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};
const PUSH_LIFETIME_SECONDS = 1800;
const RELAY_TIMEOUT_MS = 10_000;

/**
 * How this Worker pushes: to Jai's Agent Pager Worker when it is set (`pager`: that Worker alone reaches Agent Pager, so
 * the app hears from one Worker), else through the relay, else APNs with its own key, else not at all.
 */
export type PushMode = "pager" | "relay" | "apns" | "none";

export function pushMode(env: Env): PushMode {
  if (isSet(env.AGENT_PAGER_URL) && isSet(env.AGENT_PAGER_PUSH_TOKEN)) return "pager";
  if (isSet(env.PUSH_RELAY_URL) && isSet(env.PUSH_RELAY_KEY)) return "relay";
  return isSet(env.APNS_KEY_ID) && isSet(env.APNS_TEAM_ID) && isSet(env.APNS_KEY_P8) && isSet(env.APNS_BUNDLE_ID)
    ? "apns" : "none";
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function pemBytes(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  return Uint8Array.from(atob(body), (character) => character.charCodeAt(0));
}

export async function apnsJwt(env: Env, nowSeconds: number): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8", pemBytes(env.APNS_KEY_P8 ?? ""), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const encoder = new TextEncoder();
  const part = (value: object) => base64Url(encoder.encode(JSON.stringify(value)));
  const unsigned = `${part({ alg: "ES256", kid: env.APNS_KEY_ID })}.${part({ iss: env.APNS_TEAM_ID, iat: nowSeconds })}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(unsigned));
  return `${unsigned}.${base64Url(new Uint8Array(signature))}`;
}

/** APNs' status and reason. Null status: the push never reached Apple, and `reason` says why (the relay's words). */
export interface PushOutcome {
  status: number | null;
  reason: string | null;
}

/** What one push says and how APNs treats it. The silent wake and the alerts (`alerts.ts`) are both one of these. */
export interface PushMessage {
  pushType: "background" | "alert";
  priority: 5 | 10;
  collapseId: string | null;
  lifetimeSeconds: number;
  payload: { aps: object } & Record<string, unknown>;
}

/** The silent wake: `reason` is all it carries, because the phone always syncs everything. */
export const SYNC_WAKE: PushMessage = {
  pushType: "background", priority: 5, collapseId: "pr-sync", lifetimeSeconds: PUSH_LIFETIME_SECONDS,
  payload: { aps: { "content-available": 1 }, reason: "pr_sync" },
};

/** Straight to APNs, with this Worker's own key. */
export async function sendDirect(
  token: string, host: ApnsHost, jwt: string, env: Env, nowSeconds: number, message: PushMessage = SYNC_WAKE,
): Promise<PushOutcome> {
  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-push-type": message.pushType,
    "apns-priority": String(message.priority),
    "apns-topic": env.APNS_BUNDLE_ID ?? "",
    "apns-expiration": String(nowSeconds + message.lifetimeSeconds),
  };
  if (message.collapseId) {
    headers["apns-collapse-id"] = message.collapseId;
  }
  try {
    const response = await fetch(`${HOSTS[host]}/3/device/${token}`, {
      method: "POST", headers, body: JSON.stringify(message.payload),
    });
    const body = response.ok ? null : await response.json().catch(() => null) as { reason?: string } | null;
    return { status: response.status, reason: body?.reason ?? null };
  } catch {
    return { status: null, reason: "fetch_error: network" };
  }
}

/** The relay's request for the same push (docs/push-relay.md). The relay fixes the topic: the PR app's bundle id. */
export function relayBody(token: string, host: ApnsHost, nowSeconds: number, message: PushMessage = SYNC_WAKE): object {
  return {
    device_token: token, apns_env: host, push_type: message.pushType, priority: message.priority,
    collapse_id: message.collapseId, expiration: nowSeconds + message.lifetimeSeconds, payload: message.payload,
  };
}

const RELAY_REFUSALS: Record<number, string> = {
  400: "relay_rejected", 401: "relay_unauthorized", 429: "relay_rate_limited",
};

/** A relay `200` carries APNs' answer; any other status is the relay's own refusal, with no APNs status. */
export function relayOutcome(status: number, body: unknown): PushOutcome {
  if (status !== 200) {
    return { status: null, reason: RELAY_REFUSALS[status] ?? `relay_http_${status}` };
  }
  const answer = (body ?? {}) as { apns_status?: unknown; reason?: unknown };
  const reason = typeof answer.reason === "string" && answer.reason !== "" ? answer.reason : null;
  if (typeof answer.apns_status === "number") {
    return { status: answer.apns_status, reason: answer.apns_status === 200 ? null : reason };
  }
  return { status: null, reason: answer.apns_status === null && reason ? reason : "relay_bad_response" };
}

/**
 * To the Agent Pager Worker's `POST /pr-push`, which sends it to its one device as its own push and logs it. No device
 * token here: that Worker knows its phone. Never throws.
 */
export async function sendViaPager(env: Env, message: PushMessage): Promise<PushOutcome> {
  try {
    const response = await fetch(`${(env.AGENT_PAGER_URL ?? "").replace(/\/+$/, "")}/pr-push`, {
      method: "POST",
      headers: { authorization: `Bearer ${env.AGENT_PAGER_PUSH_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({
        push_type: message.pushType, priority: message.priority, collapse_id: message.collapseId,
        lifetime_seconds: message.lifetimeSeconds, payload: message.payload,
      }),
      signal: AbortSignal.timeout(RELAY_TIMEOUT_MS),
    });
    return relayOutcome(response.status, response.status === 200 ? await response.json().catch(() => null) : null);
  } catch (error) {
    const timedOut = error instanceof Error && error.name === "TimeoutError";
    return { status: null, reason: timedOut ? "fetch_error: timeout" : "fetch_error: network" };
  }
}

/** Through the relay. Never throws: a network failure is a reason like any other. */
export async function sendViaRelay(
  token: string, host: ApnsHost, env: Env, nowSeconds: number, message: PushMessage = SYNC_WAKE,
): Promise<PushOutcome> {
  try {
    const response = await fetch(`${(env.PUSH_RELAY_URL ?? "").replace(/\/+$/, "")}/v1/push`, {
      method: "POST",
      headers: { authorization: `Bearer ${env.PUSH_RELAY_KEY}`, "content-type": "application/json" },
      body: JSON.stringify(relayBody(token, host, nowSeconds, message)),
      signal: AbortSignal.timeout(RELAY_TIMEOUT_MS),
    });
    return relayOutcome(response.status, response.status === 200 ? await response.json().catch(() => null) : null);
  } catch (error) {
    const timedOut = error instanceof Error && error.name === "TimeoutError";
    return { status: null, reason: timedOut ? "fetch_error: timeout" : "fetch_error: network" };
  }
}
