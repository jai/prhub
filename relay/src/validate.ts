import { type ApnsEnvironment, isPlainObject } from "./apns.ts";

/** Apple's ceiling on a serialised payload; the contract allows up to and including it. */
export const PAYLOAD_MAX_BYTES = 4096;

/** A request body bigger than this cannot hold a valid push, so it is refused before parsing. */
export const BODY_MAX_BYTES = 16 * 1024;

const COLLAPSE_ID_MAX_BYTES = 64;
const LABEL_MAX_CHARS = 200;

export interface PushBody {
  deviceToken: string;
  apnsEnv: ApnsEnvironment;
  pushType: "alert" | "background";
  priority: 5 | 10;
  collapseId: string | null;
  expiration: number | null;
  payload: Record<string, unknown>;
}

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

const PUSH_FIELDS = new Set(["device_token", "apns_env", "push_type", "priority", "collapse_id", "expiration", "payload"]);

const encoder = new TextEncoder();

/** The `POST /v1/push` body, checked field by field; any other field is refused. */
export function parsePushBody(text: string): Parsed<PushBody> {
  const body = parseObject(text);
  if (body === null) return { ok: false, error: "invalid_json" };
  for (const field of Object.keys(body)) if (!PUSH_FIELDS.has(field)) return { ok: false, error: "unknown_field" };

  const { device_token, apns_env, push_type, priority, collapse_id, expiration, payload } = body;
  // Same rule as worker/src/devices.ts for a registered device's token; stored lowercased.
  if (typeof device_token !== "string" || !/^[0-9a-fA-F]{2,200}$/.test(device_token)) {
    return { ok: false, error: "invalid_device_token" };
  }
  if (apns_env !== "production" && apns_env !== "sandbox") return { ok: false, error: "invalid_apns_env" };
  if (push_type !== "alert" && push_type !== "background") return { ok: false, error: "invalid_push_type" };
  if (priority !== 5 && priority !== 10) return { ok: false, error: "invalid_priority" };
  if (
    collapse_id !== undefined &&
    collapse_id !== null &&
    (typeof collapse_id !== "string" || collapse_id === "" || encoder.encode(collapse_id).byteLength > COLLAPSE_ID_MAX_BYTES)
  ) {
    return { ok: false, error: "invalid_collapse_id" };
  }
  if (
    expiration !== undefined &&
    expiration !== null &&
    (typeof expiration !== "number" || !Number.isSafeInteger(expiration) || expiration < 0)
  ) {
    return { ok: false, error: "invalid_expiration" };
  }
  if (!isPlainObject(payload) || !isPlainObject(payload.aps)) return { ok: false, error: "invalid_payload" };
  if (encoder.encode(JSON.stringify(payload)).byteLength > PAYLOAD_MAX_BYTES) {
    return { ok: false, error: "payload_too_large" };
  }

  return {
    ok: true,
    value: {
      deviceToken: device_token.toLowerCase(),
      apnsEnv: apns_env,
      pushType: push_type,
      priority,
      collapseId: typeof collapse_id === "string" ? collapse_id : null,
      expiration: typeof expiration === "number" ? expiration : null,
      payload,
    },
  };
}

/** The `POST /v1/keys` body: `{"label": "<who it is for>"}`, nothing else. */
export function parseKeyBody(text: string): Parsed<{ label: string }> {
  const body = parseObject(text);
  if (body === null) return { ok: false, error: "invalid_json" };
  for (const field of Object.keys(body)) if (field !== "label") return { ok: false, error: "unknown_field" };
  const label = typeof body.label === "string" ? body.label.trim() : "";
  if (label === "" || label.length > LABEL_MAX_CHARS) return { ok: false, error: "invalid_label" };
  return { ok: true, value: { label } };
}

function parseObject(text: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(text);
    return isPlainObject(parsed) ? parsed : null;
  } catch {
    return null;
  }
}
