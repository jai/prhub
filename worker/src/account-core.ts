/**
 * One person's account on the hosted Worker (docs/api.md, "Hosted sign-in"): who they are on GitHub, their user access
 * and refresh tokens sealed at rest (`token-crypto.ts`), the session secrets of their signed-in phones, and the
 * one-time codes that hand a new session to the app. `UserAccount` (`account.ts`) holds one per person, named
 * `user:<GitHub user id>`; this file is its logic over a key-value store, so a test runs it without a Durable Object.
 */
import { z } from "zod";
import type { GitHubUser, TokenGrant } from "./boundary.ts";
import { type InstallationAccount, InstallationAccountSchema } from "./installations.ts";
import { countOf, durationOf, LimitName, type Limits } from "./limits.ts";
import { type Fetch, type OAuthApp, refreshGrant, revokeGrant } from "./oauth.ts";
import { sha256Hex } from "./pairing.ts";
import {
  type Keyring, keyIdOf, openToken, pkceChallengeOf, randomToken, sealToken, timingSafeEqual,
} from "./token-crypto.ts";

/** Refreshed this long before GitHub's 8 hours run out, so no request carries a token about to die. */
export const REFRESH_MARGIN_MS = 5 * 60_000;

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

/**
 * Kept apart from the account record, under keys of their own, so a refresh or a sign-in that writes the record back
 * never undoes a key set, or a sync done, while it waited on GitHub.
 */
const AiSchema = z.object({
  /** The person's own Anthropic key, sealed as the tokens are. */
  anthropic_key: z.string(),
  /** Ask's agent, environment and vault in the person's Anthropic org, made when they gave the key. */
  ask: z.object({
    agent_id: z.string(), environment_id: z.string(), vault_id: z.string(), credential_id: z.string(),
  }).nullable(),
});

/** The installations the person's token reached at the last sync (`installations.ts`), and when one was claimed. */
const InstallationsSchema = z.object({ ids: z.array(z.string()), synced_at: z.number() });

/** What the app shows of those installations (`GET /device/config`'s `installations`), kept apart from the ids. */
const InstallationAccountsSchema = z.array(z.unknown());

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
  /** How long a one-time code and a session live, and how many sessions a person keeps (`limits.ts`). */
  limits: Limits;
  /** Tells the person's phones to sign in again: a push, once, when GitHub stops honouring their tokens. */
  onSignedOut: (reason: SignedOutReason) => Promise<void>;
}

/** Ask's resources in the person's own Anthropic org (`ask-setup.ts`). Ids, not secrets. */
export interface AskResources {
  agent_id: string;
  environment_id: string;
  vault_id: string;
  credential_id: string;
}

/** The person's own AI settings: their Anthropic key, opened, and Ask's resources in their org. */
export interface UserAi {
  anthropicKey: string | null;
  ask: AskResources | null;
}

export const NO_AI: UserAi = { anthropicKey: null, ask: null };

/** A token to act with, or why there is none: signed out (sign in again) or GitHub could not be asked (try later). */
export type TokenAnswer =
  | { kind: "ok"; token: string; login: string; userId: string; ai: UserAi }
  | { kind: "signed_out" }
  | { kind: "unavailable" };

export interface SessionInfo {
  userId: string;
  login: string;
  state: "signed_in" | "signed_out";
  reason: SignedOutReason | null;
  /** Whether the person gave their own Anthropic key. The key itself never leaves the account. */
  hasAnthropicKey: boolean;
}

const ACCOUNT = "account";
const AI = "ai";
const INSTALLATIONS = "installations";
const INSTALLATION_ACCOUNTS = "installation_accounts";
/** Signing out drops every token and key the account holds, so none is kept for someone with no phone signed in. */
function signedOut(record: AccountRecord, reason: SignedOutReason): AccountRecord {
  return { ...record, state: "signed_out", signed_out_reason: reason, tokens: null, handoffs: [] };
}
/** The person's Anthropic key: 20 to 300 URL-safe characters. Anthropic says whether it works. */
const ANTHROPIC_KEY = /^[A-Za-z0-9_-]{20,300}$/;

export function isAnthropicKeyShape(key: unknown): key is string {
  return typeof key === "string" && ANTHROPIC_KEY.test(key);
}

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
        {
          code_hash: await sha256Hex(handoff), challenge: appChallenge,
          expires_at: now + durationOf(this.#deps.limits, LimitName.SignInCodeMinutes),
        },
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
    record.sessions = [...record.sessions.filter((session) => this.#isLive(session, now)),
      { fingerprint: await sha256Hex(secret), created_at: now }]
      .slice(-countOf(this.#deps.limits, LimitName.SessionsMax));
    await this.#write(record);
    return { secret, login: record.login, userId: String(record.user_id) };
  }

  /** Whose session this fingerprint is, and whether they are still signed in; null for one never minted or gone. */
  async session(fingerprint: string): Promise<SessionInfo | null> {
    const record = await this.#read();
    const now = this.#deps.now();
    if (!record || !record.sessions.some((session) => timingSafeEqual(session.fingerprint, fingerprint)
      && this.#isLive(session, now))) {
      return null;
    }
    return {
      userId: String(record.user_id), login: record.login, state: record.state, reason: record.signed_out_reason,
      hasAnthropicKey: (await this.#readAi()) !== null,
    };
  }

  /** A session lives `session_lifetime_days` from when it was made; after that its phone signs in again. */
  #isLive(session: { created_at: number }, now: number): boolean {
    return now - session.created_at < durationOf(this.#deps.limits, LimitName.SessionLifetimeDays);
  }

  /**
   * The re-seal sweep after a key rotation (docs/hosted-deploy.md, "Rotating the token key"): each value sealed with
   * an older key is sealed again with the first. Reading the access token does that for the tokens (`#current`, or a
   * refresh) and for the Anthropic key (`#ai`). Answers what moved, and what is still on an old key: a value whose key
   * left the keyring, which opens no more.
   */
  async resealStale(): Promise<{ current: string; resealed: SealedField[]; stale: SealedField[] } | null> {
    const keyring = await this.#deps.keyring();
    if (!keyring) {
      return null;
    }
    const before = await this.#staleFields(keyring.current);
    if (before.length > 0) {
      await this.accessToken();
    }
    const stale = await this.#staleFields(keyring.current);
    return { current: keyring.current, resealed: before.filter((field) => !stale.includes(field)), stale };
  }

  async #staleFields(current: string): Promise<SealedField[]> {
    const record = await this.#read();
    const ai = await this.#readAi();
    const sealed: [SealedField, string | null | undefined][] = [
      ["access", record?.tokens?.access], ["refresh", record?.tokens?.refresh], ["anthropic", ai?.anthropic_key],
    ];
    return sealed.flatMap(([field, value]) => value && keyIdOf(value) !== current ? [field] : []);
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
    await this.#write(signedOut(record, reason));
    await this.#deps.store.put(AI, null);
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
    await this.#write(isLast ? signedOut(record, "signed_out") : record);
    if (isLast) {
      await this.#deps.store.put(AI, null);
    }
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

  /**
   * The person's own Anthropic key, sealed, with Ask's resources in their org; null drops both. Signed-in only: false
   * when the account is signed out or gone.
   */
  async setAnthropicKey(key: string | null, ask: AskResources | null): Promise<boolean> {
    const record = await this.#read();
    if (!record || record.state !== "signed_in") {
      return false;
    }
    const keyring = await this.#deps.keyring();
    if (key !== null && !keyring) {
      throw new Error("TOKEN_ENCRYPTION_KEY is missing or malformed");
    }
    await this.#deps.store.put(AI, key !== null && keyring
      ? { anthropic_key: await sealToken(keyring, key, associatedData(record.user_id, "anthropic")), ask } : null);
    return true;
  }

  async installationIds(): Promise<string[]> {
    return (await this.#readInstallations()).ids;
  }

  /** Whether a sync of the person's installations may run now: not within `gapMs` of the last. Claimed in one turn. */
  async claimInstallationSync(now: number, gapMs: number): Promise<boolean> {
    const held = await this.#readInstallations();
    if (!(await this.isSignedIn()) || now - held.synced_at < gapMs) {
      return false;
    }
    await this.#deps.store.put(INSTALLATIONS, { ...held, synced_at: now });
    return true;
  }

  async setInstallations(ids: string[], now: number, accounts: InstallationAccount[]): Promise<void> {
    if (await this.#read()) {
      await this.#deps.store.put(INSTALLATIONS, { ids, synced_at: now });
      await this.#deps.store.put(INSTALLATION_ACCOUNTS, accounts);
    }
  }

  /**
   * The installations the last sync read, as the app shows them; null before the first. One that no longer parses is
   * left out.
   */
  async installationAccounts(): Promise<InstallationAccount[] | null> {
    const parsed = InstallationAccountsSchema.safeParse(await this.#deps.store.get(INSTALLATION_ACCOUNTS));
    if (!parsed.success) {
      return null;
    }
    return parsed.data.flatMap((entry) => {
      const account = InstallationAccountSchema.safeParse(entry);
      return account.success ? [account.data] : [];
    });
  }

  async #readInstallations(): Promise<z.infer<typeof InstallationsSchema>> {
    const parsed = InstallationsSchema.safeParse(await this.#deps.store.get(INSTALLATIONS));
    return parsed.success ? parsed.data : { ids: [], synced_at: 0 };
  }

  async #readAi(): Promise<z.infer<typeof AiSchema> | null> {
    const parsed = AiSchema.safeParse(await this.#deps.store.get(AI));
    return parsed.success ? parsed.data : null;
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
    return {
      kind: "ok", token: outcome.grant.access_token, login: record.login, userId: String(record.user_id),
      ai: keyring ? await this.#ai(record, keyring) : NO_AI,
    };
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
    return {
      kind: "ok", token: access.plaintext, login: record.login, userId: String(record.user_id),
      ai: await this.#ai(record, keyring),
    };
  }

  /** The Anthropic key opened, or no AI when there is none or it does not open (never sent anywhere then). */
  async #ai(record: AccountRecord, keyring: Keyring): Promise<UserAi> {
    const ai = await this.#readAi();
    if (!ai) {
      return NO_AI;
    }
    const opened = await openToken(keyring, ai.anthropic_key, associatedData(record.user_id, "anthropic"));
    if (opened?.isStale) {
      await this.#deps.store.put(AI, {
        ...ai, anthropic_key: await sealToken(keyring, opened.plaintext, associatedData(record.user_id, "anthropic")),
      });
    }
    return opened ? { anthropicKey: opened.plaintext, ask: ai.ask } : NO_AI;
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

export type SealedField = "access" | "refresh" | "anthropic";

/** Whose secret and which: a sealed value moved to another person or field fails to open. */
export function associatedData(userId: number, kind: SealedField): string {
  return `prhub:user:${userId}:${kind}`;
}
