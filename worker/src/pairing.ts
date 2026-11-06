/**
 * Pairing a self-hosted Worker with the PR app (docs/api/pr-selfhost.md), as the Pager Worker pairs (docs/api/selfhost.md
 * §12.2): `npm run pair` puts a one-time code's record in R2, and `POST /device/pair` spends it to admit the app's device
 * secret. Nothing here calls anything.
 */

export interface PairingRecord {
  role: "device" | "app";
  label: string | null;
  created_at: string;
  expires_at: string;
}

/** Crockford base32 without I, L, O, U, eight characters. */
const CODE = /^[0-9A-HJKMNP-TV-Z]{8}$/;

/** A code as typed or scanned: case, spaces and hyphens don't matter. Null when it is not one. */
export function normalizePairingCode(raw: unknown): string | null {
  if (typeof raw !== "string" || raw.length > 32) return null;
  const code = raw.replace(/[\s-]/g, "").toUpperCase();
  return CODE.test(code) ? code : null;
}

/** The bearer of a request, when it could be a device secret: 16 to 512 characters. */
export function deviceSecretOf(header: string | null): string | null {
  const secret = /^Bearer (.+)$/.exec(header ?? "")?.[1] ?? null;
  return secret !== null && secret.length >= 16 && secret.length <= 512 ? secret : null;
}

/** SHA-256 of the UTF-8 bytes, lowercase hex: a device secret's fingerprint, and a code's name in R2. */
export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function pairingKey(codeHash: string): string {
  return `pair/${codeHash}.json`;
}

export function isPairingRecord(value: unknown): value is PairingRecord {
  const record = value as Partial<PairingRecord> | null;
  return typeof record === "object" && record !== null
    && (record.role === "device" || record.role === "app")
    && (record.label === null || typeof record.label === "string")
    && typeof record.created_at === "string"
    && typeof record.expires_at === "string" && !Number.isNaN(Date.parse(record.expires_at));
}
