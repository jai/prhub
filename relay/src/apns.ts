// JWT minting and the APNs request are copied from worker/src/apns.ts (pemToDer, importApnsKey, mintApnsJwt,
// readApnsResponse). worker/ imports without extensions and pulls in its KV cache, so it cannot be shared as is.

/** APNs hosts by the device's build environment; the path is always `/3/device/<token>`. */
export const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

export type ApnsEnvironment = keyof typeof APNS_HOSTS;

/** The same shape as worker/src/apns.ts `PushResult`, so a self-hosted Worker records it as a direct send. */
export interface PushResult {
  apns_status: number | null;
  apns_id: string | null;
  reason: string | null;
}

/** Seconds a provider token is reused: inside Apple's "refresh between 20 and 60 minutes" window. */
export const JWT_REUSE_SECONDS = 50 * 60;

const APNS_TIMEOUT_MS = 10_000;

export function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const base64 = pem
    .replace(/-----BEGIN [^-]*-----/g, "")
    .replace(/-----END [^-]*-----/g, "")
    .replace(/\s+/g, "");
  if (base64 === "" || !/^[A-Za-z0-9+/]+=*$/.test(base64)) throw new Error("apns key PEM has no base64 body");
  return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
}

export async function importApnsKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("pkcs8", pemToDer(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** ES256 provider token; WebCrypto's raw r‖s signature is already JWS form. */
export async function mintApnsJwt(key: CryptoKey, kid: string, iss: string, iat: number): Promise<string> {
  const encoder = new TextEncoder();
  const header = base64Url(encoder.encode(JSON.stringify({ alg: "ES256", kid })));
  const claims = base64Url(encoder.encode(JSON.stringify({ iss, iat })));
  const signingInput = `${header}.${claims}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(signingInput));
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

export function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** What goes to APNs besides the device token and the provider token. */
export interface ApnsRequest {
  apnsEnv: ApnsEnvironment;
  deviceToken: string;
  topic: string;
  pushType: "alert" | "background";
  priority: 5 | 10;
  collapseId: string | null;
  expiration: number | null;
  payload: Record<string, unknown>;
}

/** One APNs request. Never throws: a thrown or timed-out fetch is `fetch_error: …`, like worker/src/apns.ts. */
export async function sendToApns(fetcher: typeof fetch, jwt: string, request: ApnsRequest): Promise<PushResult> {
  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "content-type": "application/json",
    "apns-push-type": request.pushType,
    "apns-priority": String(request.priority),
    "apns-topic": request.topic,
  };
  if (request.collapseId !== null) headers["apns-collapse-id"] = request.collapseId;
  if (request.expiration !== null) headers["apns-expiration"] = String(request.expiration);

  let response: Response;
  try {
    response = await fetcher(`${APNS_HOSTS[request.apnsEnv]}/3/device/${request.deviceToken}`, {
      method: "POST",
      headers,
      body: JSON.stringify(request.payload),
      signal: AbortSignal.timeout(APNS_TIMEOUT_MS),
    });
  } catch (error) {
    // Fixed values, never the thrown message: it can carry the URL, and the URL carries the device token.
    const timedOut = error instanceof Error && error.name === "TimeoutError";
    return { apns_status: null, apns_id: null, reason: timedOut ? "fetch_error: timeout" : "fetch_error: network" };
  }
  return readApnsResponse(response);
}

/** Whether a 403 means the provider token is dead and must be re-minted; a 429 never does. */
export function invalidatesProviderToken(result: PushResult): boolean {
  return (
    result.apns_status === 403 &&
    (result.reason === "ExpiredProviderToken" || result.reason === "InvalidProviderToken" || result.reason === "http_403")
  );
}

async function readApnsResponse(response: Response): Promise<PushResult> {
  const apnsId = response.headers.get("apns-id");
  if (response.status === 200) return { apns_status: 200, apns_id: apnsId, reason: null };
  let reason = `http_${response.status}`;
  try {
    const text = await response.text();
    if (text !== "") {
      const parsed: unknown = JSON.parse(text);
      if (isPlainObject(parsed) && typeof parsed.reason === "string" && parsed.reason !== "") reason = parsed.reason;
    }
  } catch {
    // keep http_<status>
  }
  return { apns_status: response.status, apns_id: apnsId, reason };
}

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
