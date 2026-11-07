/**
 * GitHub tokens at rest (hosted mode): AES-256-GCM through Web Crypto, a new 12-byte IV for every seal, and associated
 * data that names whose token it is and which one, so a sealed value moved to another person or field fails to open.
 *
 * `TOKEN_ENCRYPTION_KEY` is a keyring: `<key id>:<base64 of 32 bytes>`, comma-separated. The first key seals; every
 * key opens what it sealed. To rotate, put a new key first and keep the old one after it until every value has been
 * sealed again (`openToken` says when one was sealed with an older key).
 */

const VERSION = "v1";
const KEY_ID = /^[A-Za-z0-9_-]{1,16}$/;
const IV_BYTES = 12;

export interface Keyring {
  current: string;
  keys: Map<string, CryptoKey>;
}

export function base64UrlOf(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function bytesOfBase64Url(text: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) {
    return null;
  }
  try {
    const binary = atob(text.replaceAll("-", "+").replaceAll("_", "/"));
    return Uint8Array.from(binary, (char) => char.charCodeAt(0));
  } catch {
    return null;
  }
}

function bytesOfBase64(text: string): Uint8Array<ArrayBuffer> | null {
  return bytesOfBase64Url(text.trim().replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, ""));
}

/** The keyring in `TOKEN_ENCRYPTION_KEY`; null when any entry is not `<id>:<32 bytes in base64>` or an id repeats. */
export async function parseKeyring(raw: string | undefined): Promise<Keyring | null> {
  const entries = (raw ?? "").split(",").map((entry) => entry.trim()).filter(Boolean);
  if (entries.length === 0) {
    return null;
  }
  const keys = new Map<string, CryptoKey>();
  for (const entry of entries) {
    const separator = entry.indexOf(":");
    const id = entry.slice(0, separator);
    const bytes = separator > 0 ? bytesOfBase64(entry.slice(separator + 1)) : null;
    if (!KEY_ID.test(id) || !bytes || bytes.byteLength !== 32 || keys.has(id)) {
      return null;
    }
    keys.set(id, await crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]));
  }
  return { current: entries[0].slice(0, entries[0].indexOf(":")), keys };
}

/** `v1.<key id>.<iv>.<ciphertext and tag>`, base64url. */
export async function sealToken(keyring: Keyring, plaintext: string, associated: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const key = keyring.keys.get(keyring.current) as CryptoKey;
  const sealed = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(associated) }, key,
    new TextEncoder().encode(plaintext));
  return [VERSION, keyring.current, base64UrlOf(iv), base64UrlOf(new Uint8Array(sealed))].join(".");
}

/** The id of the key that sealed a value; null for one that is not `v1.<key id>.…`. */
export function keyIdOf(sealed: string): string | null {
  const [version, keyId] = sealed.split(".");
  return version === VERSION && keyId !== undefined && KEY_ID.test(keyId) ? keyId : null;
}

/**
 * The token, and whether it was sealed with an older key and should be sealed again. Null when it is not one of ours:
 * an unknown key id, a changed byte, or associated data for someone or something else.
 */
export async function openToken(
  keyring: Keyring, sealed: string, associated: string,
): Promise<{ plaintext: string; isStale: boolean } | null> {
  const [version, keyId, ivText, bodyText, ...rest] = sealed.split(".");
  const key = keyring.keys.get(keyId ?? "");
  const iv = bytesOfBase64Url(ivText ?? "");
  const body = bytesOfBase64Url(bodyText ?? "");
  if (version !== VERSION || rest.length > 0 || !key || !iv || iv.byteLength !== IV_BYTES || !body) {
    return null;
  }
  try {
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(associated) }, key, body);
    return { plaintext: new TextDecoder().decode(plain), isStale: keyId !== keyring.current };
  } catch {
    return null;
  }
}

/** Random bytes as base64url: 32 bytes is 43 characters. */
export function randomToken(bytes = 32): string {
  return base64UrlOf(crypto.getRandomValues(new Uint8Array(bytes)));
}

/** PKCE's S256: base64url of the SHA-256 of the verifier's ASCII. */
export async function pkceChallengeOf(verifier: string): Promise<string> {
  return base64UrlOf(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

/** RFC 7636: 43 to 128 unreserved characters. */
export function isPkceVerifier(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9._~-]{43,128}$/.test(value);
}

/** An S256 challenge: 43 base64url characters. */
export function isPkceChallenge(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value);
}

/** Equal strings in time that does not depend on where they differ. */
export function timingSafeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  let difference = left.byteLength ^ right.byteLength;
  for (let index = 0; index < Math.max(left.byteLength, right.byteLength); index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}
