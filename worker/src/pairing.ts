/**
 * Pairing a self-hosted Worker with the PR app (docs/api.md): `npm run pair` puts a one-time code's record in R2, and
 * `POST /device/pair` spends it to admit the app's device secret. Nothing here calls anything but the index it is handed.
 */
import { z } from "zod";
import type { CodeHash, Fingerprint } from "./ids.ts";

const PairingRecordSchema = z.object({
  role: z.enum(["device", "app"]),
  label: z.string().nullable(),
  created_at: z.string(),
  expires_at: z.string().refine((value) => !Number.isNaN(Date.parse(value))),
});

export type PairingRecord = z.infer<typeof PairingRecordSchema>;

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

export async function fingerprintOf(secret: string): Promise<Fingerprint> {
  return await sha256Hex(secret) as Fingerprint;
}

/** `code` as `normalizePairingCode` gives it. */
export async function codeHashOf(code: string): Promise<CodeHash> {
  return await sha256Hex(code) as CodeHash;
}

export function pairingKey(codeHash: CodeHash): string {
  return `pair/${codeHash}.json`;
}

/** A pairing record read back from R2; null when it is not one, which pairs nothing. */
export function parsePairingRecord(value: unknown): PairingRecord | null {
  const parsed = PairingRecordSchema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

export function isPairingRecord(value: unknown): value is PairingRecord {
  return parsePairingRecord(value) !== null;
}

/** What says whether a fingerprint is paired: the PR index. */
export interface PairedDevices {
  isPaired(fingerprint: Fingerprint): boolean | Promise<boolean>;
}

/**
 * Whether a request's bearer is a paired device secret. Asked of the index every time, with no copy kept in the isolate,
 * so a secret unpaired on one isolate stops working on all of them at once.
 */
export async function isPairedSecret(authorization: string | null, devices: PairedDevices): Promise<boolean> {
  const secret = deviceSecretOf(authorization);
  return secret !== null && await devices.isPaired(await fingerprintOf(secret));
}
