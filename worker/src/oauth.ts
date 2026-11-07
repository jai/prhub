/**
 * GitHub's OAuth endpoints for the hosted App's user access tokens (docs/api.md, "Hosted sign-in"). Each call takes
 * `fetch`, so a test answers for GitHub.
 */
import { type GitHubUser, parseGitHubUser, parseOAuthError, parseTokenGrant, type TokenGrant } from "./boundary.ts";

export type Fetch = typeof fetch;

export interface OAuthApp {
  clientId: string;
  clientSecret: string;
}

/** What the token endpoint said: a pair, GitHub's refusal by name, or no answer worth reading. */
export type GrantOutcome =
  | { kind: "granted"; grant: TokenGrant }
  | { kind: "refused"; error: string }
  | { kind: "unavailable"; status: number };

const HEADERS = { Accept: "application/json", "User-Agent": "pr-viewer" };

export function authorizeUrl(
  app: OAuthApp, redirectUri: string, state: string, codeChallenge: string,
): string {
  const params = new URLSearchParams({
    client_id: app.clientId, redirect_uri: redirectUri, state, code_challenge: codeChallenge,
    code_challenge_method: "S256",
  });
  return `https://github.com/login/oauth/authorize?${params}`;
}

async function tokenRequest(fields: Record<string, string>, fetcher: Fetch): Promise<GrantOutcome> {
  let response: Response;
  try {
    response = await fetcher("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: { ...HEADERS, "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(fields).toString(),
    });
  } catch {
    return { kind: "unavailable", status: 0 };
  }
  const body: unknown = await response.json().catch(() => null);
  const refusal = parseOAuthError(body);
  if (refusal) {
    return { kind: "refused", error: refusal.error };
  }
  const grant = response.ok ? parseTokenGrant(body) : null;
  return grant ? { kind: "granted", grant } : { kind: "unavailable", status: response.status };
}

/** The code from the callback, traded with the verifier behind the challenge the authorize URL carried. */
export function exchangeCode(
  app: OAuthApp, code: string, codeVerifier: string, redirectUri: string, fetcher: Fetch,
): Promise<GrantOutcome> {
  return tokenRequest({
    client_id: app.clientId, client_secret: app.clientSecret, code, code_verifier: codeVerifier,
    redirect_uri: redirectUri,
  }, fetcher);
}

/** A new pair for the refresh token; GitHub kills the old pair as it answers. */
export function refreshGrant(app: OAuthApp, refreshToken: string, fetcher: Fetch): Promise<GrantOutcome> {
  return tokenRequest({
    client_id: app.clientId, client_secret: app.clientSecret, grant_type: "refresh_token",
    refresh_token: refreshToken,
  }, fetcher);
}

/** The person a token acts as; null when GitHub would not say. */
export async function readUser(token: string, fetcher: Fetch): Promise<GitHubUser | null> {
  try {
    const response = await fetcher("https://api.github.com/user", {
      headers: { ...HEADERS, Accept: "application/vnd.github+json", Authorization: `Bearer ${token}` },
    });
    return response.ok ? parseGitHubUser(await response.json().catch(() => null)) : null;
  } catch {
    return null;
  }
}

/**
 * Revokes the person's authorization of the App and every token it issued them (`DELETE /applications/{id}/grant`).
 * GitHub answers 204, or 404 when it is already gone; both count as done.
 */
export async function revokeGrant(app: OAuthApp, accessToken: string, fetcher: Fetch): Promise<boolean> {
  try {
    const response = await fetcher(`https://api.github.com/applications/${encodeURIComponent(app.clientId)}/grant`, {
      method: "DELETE",
      headers: {
        ...HEADERS, Accept: "application/vnd.github+json", "Content-Type": "application/json",
        Authorization: `Basic ${btoa(`${app.clientId}:${app.clientSecret}`)}`,
      },
      body: JSON.stringify({ access_token: accessToken }),
    });
    return response.status === 204 || response.status === 404;
  } catch {
    return false;
  }
}
