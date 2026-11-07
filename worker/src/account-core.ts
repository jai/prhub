/**
 * One person's account on the hosted Worker (docs/api.md, "Hosted sign-in"): who they are on GitHub, their user access
 * and refresh tokens sealed at rest (`token-crypto.ts`), the session secrets of their signed-in phones, and the
 * one-time codes that hand a new session to the app. `UserAccount` (`account.ts`) holds one per person, named
 * `user:<GitHub user id>`; this file is its logic over a key-value store, so a test runs it without a Durable Object.
 */
import { z } from "zod";
import type { GitHubUser, TokenGrant } from "./boundary.ts";
import { type Fetch, type OAuthApp, refreshGrant, revokeGrant } from "./oauth.ts";
import { sha256Hex } from "./pairing.ts";
import {
  type Keyring, openToken, pkceChallengeOf, randomToken, sealToken, timingSafeEqual,
} from "./token-crypto.ts";

/** Refreshed this long before GitHub's 8 hours run out, so no request carries a token about to die. */
export const REFRESH_MARGIN_MS = 5 * 60_000;
/** How long the app has to swap the callback's one-time code for its session. */
export const HANDOFF_MS = 5 * 60_000;
/** Signed-in phones kept per person; the oldest session goes first. */
export const MAX_SESSIONS = 20;

/** `<user id>.<43 base64url characters>`: a session secret, and the one-time code that hands one over. */
const SECRET = /^([1-9]\d{0,15})\.([A-Za-z0-9_-]{43})$/;

/** The user id a session secret or handoff code names; null when it is not one. */
export function userIdOf(secret: string | null): string | null {
  return SECRET.exec(secret ?? "")?.[1] ?? null;
}

export type SignedOutReason = "revoked" | "refresh_expired" | "signed_out";

const AccountSchema = z.object({
  user_id: z.number().int().positive(),
  login: z.string(),
  created_at: z.number(),
  state: z.enum(["signed_in", "signed_out"]),
  signed_out_reason: z.enum(["revoked", "refresh_expired", "signed_out"]).nullable(),
  tokens: z.object({
    access: z.string(),
    refresh: z.string().nullable(),
    access_expires_at: z.number().nullable(),
    refresh_expires_at: z.number().nullable(),
  }).nullable(),
  sessions: z.array(z.object({ fingerprint: z.string(), created_at: z.number() })),
  handoffs: z.array(z.object({ code_hash: z.string(), challenge: z.string(), expires_at: z.number() })),
});

type AccountRecord = z.infer<typeof AccountSchema>;

/** The slice of `DurableObjectStorage` the account uses; a test passes a Map. */
export interface KeyValueStore {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
  deleteAll(): Promise<void>;
}

export interface AccountDeps {
  store: KeyValueStore;
  /** `TOKEN_ENCRYPTION_KEY`, parsed; null when it is missing or malformed, and then no token is sealed or opened. */
  keyring: () => Promise<Keyring | null>;
  app: OAuthApp;
  fetch: Fetch;
  now: () => number;
  /** Tells the person's phones to sign in again: a push, once, when GitHub stops honouring their tokens. */
  onSignedOut: (reason: SignedOutReason) => Promise<void>;
}

/** A token to act with, or why there is none: signed out (sign in again) or GitHub could not be asked (try later). */
export type TokenAnswer =
  | { kind: "ok"; token: string; login: string; userId: string }
  | { kind: "signed_out" }
  | { kind: "unavailable" };

export interface SessionInfo {
  userId: string;
  login: string;
  state: "signed_in" | "signed_out";
  reason: SignedOutReason | null;
}

const ACCOUNT = "account";

export class AccountCore {
  readonly #deps: AccountDeps;
  #refreshing: Promise<TokenAnswer> | null = null;

  constructor(deps: AccountDeps) {
    this.#deps = deps;
  }

  /**
   * GitHub said who this is and gave their tokens: keep both, sealed, and mint the one-time code the app swaps for its
   * session with the PKCE verifier behind `appChallenge`. Signing in again replaces the tokens and keeps other phones.
   */
  async signIn(user: GitHubUser, grant: TokenGrant, appChallenge: string): Promise<{ handoff: string }> {
    const now = this.#deps.now();
    const held = await this.#read();
    const tokens = await this.#seal(user.id, grant, now);
    const handoff = `${user.id}.${randomToken()}`;
    const record: AccountRecord = {
      user_id: user.id,
      login: user.login,
      created_at: held?.created_at ?? now,
      state: "signed_in",
      signed_out_reason: null,
      tokens,
      sessions: held?.sessions ?? [],
      handoffs: [
        ...(held?.handoffs ?? []).filter((entry) => entry.expires_at > now),
        { code_hash: await sha256Hex(handoff), challenge: appChallenge, expires_at: now + HANDOFF_MS },
      ],
    };
    await this.#write(record);
    return { handoff };
  }

  /**
   * The app's half: the one-time code and the verifier whose S256 the app sent to `/auth/github/start`. The code is
   * spent before anything else is checked, so a wrong verifier burns it too. Null for anything but a match.
   */
  async finish(handoff: string, verifier: string): Promise<{ secret: string; login: string; userId: string } | null> {
    const now = this.#deps.now();
    const record = await this.#read();
    if (!record) {
      return null;
    }
    const codeHash = await sha256Hex(handoff);
    const entry = record.handoffs.find((candidate) => timingSafeEqual(candidate.code_hash, codeHash));
    record.handoffs = record.handoffs.filter((candidate) => candidate !== entry && candidate.expires_at > now);
    await this.#write(record);
    if (!entry || entry.expires_at <= now || record.state !== "signed_in"
      || !timingSafeEqual(await pkceChallengeOf(verifier), entry.challenge)) {
      return null;
    }
    const secret = `${record.user_id}.${randomToken()}`;
    record.sessions = [...record.sessions, { fingerprint: await sha256Hex(secret), created_at: now }]
      .slice(-MAX_SESSIONS);
    await this.#write(record);
    return { secret, login: record.login, userId: String(record.user_id) };
  }

  /** Whose session this fingerprint is, and whether they are still signed in; null for one never minted or gone. */
  async session(fingerprint: string): Promise<SessionInfo | null> {
    const record = await this.#read();
    if (!record || !record.sessions.some((session) => timingSafeEqual(session.fingerprint, fingerprint))) {
      return null;
    }
    return {
      userId: String(record.user_id), login: record.login, state: record.state, reason: record.signed_out_reason,
    };
  }

  async isSignedIn(): Promise<boolean> {
    return (await this.#read())?.state === "signed_in";
  }

  /** The access token, refreshed first when it has under `REFRESH_MARGIN_MS` left. */
  async accessToken(): Promise<TokenAnswer> {
    const record = await this.#read();
    if (!record?.tokens || record.state !== "signed_in") {
      return { kind: "signed_out" };
    }
    const expiresAt = record.tokens.access_expires_at;
    if (expiresAt !== null && expiresAt - this.#deps.now() < REFRESH_MARGIN_MS) {
      return this.#refreshOnce(null);
    }
    return this.#current(record);
  }

  /**
   * GitHub answered 401 to `stale`. When another request already replaced it, the replacement; else a refresh, which
   * tells a token GitHub dropped early from an authorization the person revoked.
   */
  async tokenAfterUnauthorized(stale: string): Promise<TokenAnswer> {
    const record = await this.#read();
    if (!record?.tokens || record.state !== "signed_in") {
      return { kind: "signed_out" };
    }
    const current = await this.#current(record);
    if (current.kind === "ok" && !timingSafeEqual(current.token, stale)) {
      return current;
    }
    return this.#refreshOnce(stale);
  }

  /** GitHub says the person revoked the App, or a refresh was refused: drop the tokens and ask the phones to sign in. */
  async signOutEverywhere(reason: SignedOutReason): Promise<void> {
    const record = await this.#read();
    if (!record || record.state === "signed_out") {
      return;
    }
    await this.#write({ ...record, state: "signed_out", signed_out_reason: reason, tokens: null, handoffs: [] });
    await this.#deps.onSignedOut(reason)
      .catch((error: unknown) => console.error("sign-in-again push failed", error));
  }

  /**
   * One phone signs out: its session ends. The last one to go takes the tokens with it, so the Worker holds no token
   * for someone with no phone signed in. Answers whether that was the last.
   */
  async signOut(fingerprint: string): Promise<boolean> {
    const record = await this.#read();
    if (!record) {
      return false;
    }
    record.sessions = record.sessions.filter((session) => !timingSafeEqual(session.fingerprint, fingerprint));
    const isLast = record.sessions.length === 0;
    await this.#write(isLast
      ? { ...record, state: "signed_out", signed_out_reason: "signed_out", tokens: null, handoffs: [] }
      : record);
    return isLast;
  }

  /**
   * Delete Account: GitHub revokes the authorization and every token it gave PRHub for this person, then everything
   * this object holds goes. A revoke GitHub could not take still deletes here; answers whether GitHub took it.
   */
  async deleteAccount(): Promise<{ revoked: boolean }> {
    const record = await this.#read();
    let revoked = !record?.tokens;
    if (record?.tokens) {
      const current = await this.#current(record);
      revoked = current.kind === "ok" && await revokeGrant(this.#deps.app, current.token, this.#deps.fetch);
    }
    await this.#deps.store.deleteAll();
    return { revoked };
  }

  #refreshOnce(stale: string | null): Promise<TokenAnswer> {
    // One refresh at a time: GitHub kills the pair a refresh used, so a second one at once would sign the person out.
    this.#refreshing ??= this.#refresh(stale).finally(() => {
      this.#refreshing = null;
    });
    return this.#refreshing;
  }

  async #refresh(stale: string | null): Promise<TokenAnswer> {
    const now = this.#deps.now();
    const record = await this.#read();
    if (!record?.tokens || record.state !== "signed_in") {
      return { kind: "signed_out" };
    }
    const keyring = await this.#deps.keyring();
    const associated = associatedData(record.user_id, "refresh");
    const refresh = keyring && record.tokens.refresh
      ? await openToken(keyring, record.tokens.refresh, associated) : null;
    const current = await this.#current(record);
    const accessLives = record.tokens.access_expires_at === null || record.tokens.access_expires_at > now;
    if (record.tokens.refresh === null) {
      // Token expiration is off for the App: nothing to refresh, and a 401 means the person revoked it.
      if (stale === null) {
        return current;
      }
      await this.signOutEverywhere("revoked");
      return { kind: "signed_out" };
    }
    if (!refresh) {
      // The key, not the person: keep the tokens until the keyring opens them again.
      return { kind: "unavailable" };
    }
    if (record.tokens.refresh_expires_at !== null && record.tokens.refresh_expires_at <= now) {
      await this.signOutEverywhere("refresh_expired");
      return { kind: "signed_out" };
    }
    const outcome = await refreshGrant(this.#deps.app, refresh.plaintext, this.#deps.fetch);
    if (outcome.kind === "refused" && outcome.error === "bad_refresh_token") {
      await this.signOutEverywhere("revoked");
      return { kind: "signed_out" };
    }
    if (outcome.kind !== "granted") {
      // GitHub is down or the App's own credentials are wrong: the person did nothing, so they stay signed in.
      return accessLives && stale === null ? current : { kind: "unavailable" };
    }
    const tokens = await this.#seal(record.user_id, outcome.grant, now);
    await this.#write({ ...record, tokens });
    return { kind: "ok", token: outcome.grant.access_token, login: record.login, userId: String(record.user_id) };
  }

  /** The access token as held, sealed again with the current key when an older one sealed it. */
  async #current(record: AccountRecord): Promise<TokenAnswer> {
    const keyring = await this.#deps.keyring();
    if (!keyring || !record.tokens) {
      return { kind: record.tokens ? "unavailable" : "signed_out" };
    }
    const access = await openToken(keyring, record.tokens.access, associatedData(record.user_id, "access"));
    if (!access) {
      // Not ours, or changed at rest: never sent to GitHub.
      return { kind: "unavailable" };
    }
    if (access.isStale) {
      await this.#reseal(record, keyring);
    }
    return { kind: "ok", token: access.plaintext, login: record.login, userId: String(record.user_id) };
  }

  async #reseal(record: AccountRecord, keyring: Keyring): Promise<void> {
    const tokens = record.tokens;
    if (!tokens) {
      return;
    }
    const access = await openToken(keyring, tokens.access, associatedData(record.user_id, "access"));
    const refresh = tokens.refresh ? await openToken(keyring, tokens.refresh, associatedData(record.user_id, "refresh"))
      : null;
    if (!access || (tokens.refresh && !refresh)) {
      return;
    }
    await this.#write({
      ...record,
      tokens: {
        ...tokens,
        access: await sealToken(keyring, access.plaintext, associatedData(record.user_id, "access")),
        refresh: refresh ? await sealToken(keyring, refresh.plaintext, associatedData(record.user_id, "refresh")) : null,
      },
    });
  }

  async #seal(userId: number, grant: TokenGrant, now: number): Promise<NonNullable<AccountRecord["tokens"]>> {
    const keyring = await this.#deps.keyring();
    if (!keyring) {
      throw new Error("TOKEN_ENCRYPTION_KEY is missing or malformed");
    }
    return {
      access: await sealToken(keyring, grant.access_token, associatedData(userId, "access")),
      refresh: grant.refresh_token
        ? await sealToken(keyring, grant.refresh_token, associatedData(userId, "refresh")) : null,
      access_expires_at: grant.expires_in === null ? null : now + grant.expires_in * 1_000,
      refresh_expires_at: grant.refresh_token_expires_in === null ? null : now + grant.refresh_token_expires_in * 1_000,
    };
  }

  async #read(): Promise<AccountRecord | null> {
    const parsed = AccountSchema.safeParse(await this.#deps.store.get(ACCOUNT));
    return parsed.success ? parsed.data : null;
  }

  async #write(record: AccountRecord): Promise<void> {
    await this.#deps.store.put(ACCOUNT, record);
  }
}

/** Whose token and which: a sealed value moved to another person or field fails to open. */
export function associatedData(userId: number, kind: "access" | "refresh"): string {
  return `prhub:user:${userId}:${kind}`;
}
