import { base64Url } from "./apns.ts";

const encoder = new TextEncoder();

/** A new key: the id is public, the key is shown once and only its SHA-256 is kept. */
export function newKey(): { keyId: string; key: string } {
  const id = crypto.getRandomValues(new Uint8Array(8));
  const secret = crypto.getRandomValues(new Uint8Array(32));
  return { keyId: `rk_${hex(id)}`, key: `rks_${base64Url(secret)}` };
}

export async function sha256Hex(value: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

/** Compares digests of both, so neither the length nor the first differing byte shows in the timing. */
export async function constantTimeEqual(a: string, b: string): Promise<boolean> {
  const [left, right] = await Promise.all([digest(a), digest(b)]);
  let difference = 0;
  for (let i = 0; i < left.length; i++) difference |= (left[i] ?? 0) ^ (right[i] ?? 0);
  return difference === 0;
}

/** The bearer token of `Authorization: Bearer <token>`, or null. */
export function bearerToken(request: Request): string | null {
  const match = /^Bearer (\S+)$/.exec(request.headers.get("authorization") ?? "");
  return match?.[1] ?? null;
}

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
