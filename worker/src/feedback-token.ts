/**
 * FeedbackKit's direct path (jai/feedbackkit docs/api.md, "Direct" and "Tokens"): the app talks to FeedbackKit's
 * Worker itself, with a token this Worker signs for the person it acts for, as this app. HS256 over the app's key,
 * which FeedbackKit's Worker also holds (`APP_KEYS`); claims `iss` the app, `sub` the GitHub login, `aud`
 * "feedbackkit", `iat` and `exp` at most 15 minutes apart. Nothing passes between the two Workers.
 */
import { isSet, type Env } from "./env.ts";

export const FEEDBACKKIT_AUDIENCE = "feedbackkit";
export const TOKEN_LIFETIME_SECONDS = 15 * 60;

/** What `POST /feedback/token` answers: the token, when it ends, and the FeedbackKit Worker's root to use it at. */
export interface FeedbackToken {
  token: string;
  expires_at: string;
  url: string;
}

/** The direct path is on when this Worker can sign (`FEEDBACKKIT_APP_KEY`), as an app, for a public FeedbackKit. */
export function feedbackDirectURL(env: Env): string | null {
  if (!isSet(env.FEEDBACKKIT_APP_KEY) || !isSet(env.FEEDBACKKIT_APP) || !isSet(env.FEEDBACKKIT_PUBLIC_URL)) {
    return null;
  }
  const url = env.FEEDBACKKIT_PUBLIC_URL!.replace(/\/$/, "");
  return url.startsWith("https://") ? url : null;
}

const encoder = new TextEncoder();

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A token for `login` as `app`, signed with `key`, good from `now` (ms) for 15 minutes. */
export async function signFeedbackToken(key: string, app: string, login: string, now: number): Promise<{
  token: string; expiresAt: number;
}> {
  const iat = Math.floor(now / 1000);
  const exp = iat + TOKEN_LIFETIME_SECONDS;
  const header = base64url(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const payload = base64url(encoder.encode(JSON.stringify({ iss: app, sub: login, aud: FEEDBACKKIT_AUDIENCE, iat, exp })));
  const hmac = await crypto.subtle.importKey("raw", encoder.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", hmac, encoder.encode(`${header}.${payload}`)));
  return { token: `${header}.${payload}.${base64url(signature)}`, expiresAt: exp * 1000 };
}

/** `POST /feedback/token`: a token for the person this Worker acts for, or 404 while the direct path is off. */
export async function feedbackTokenRoute(env: Env, login: string, now = Date.now()): Promise<Response> {
  const url = feedbackDirectURL(env);
  if (!url) {
    return Response.json({ error: "Direct feedback is not configured" }, { status: 404 });
  }
  const { token, expiresAt } = await signFeedbackToken(env.FEEDBACKKIT_APP_KEY!, env.FEEDBACKKIT_APP!, login, now);
  const answer: FeedbackToken = { token, expires_at: new Date(expiresAt).toISOString(), url };
  return Response.json(answer, { headers: { "Cache-Control": "no-store" } });
}
