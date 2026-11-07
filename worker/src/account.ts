/**
 * The hosted Worker's Durable Objects for sign-in (docs/api.md, "Hosted sign-in"): `UserAccount`, one per person named
 * `user:<GitHub user id>`, and `SignIn`, one per sign-in in flight named by its state. Their logic is in
 * `account-core.ts` and `hosted.ts`; these classes only give it storage and alarms.
 */
import { DurableObject } from "cloudflare:workers";
import { AccountCore, type SignedOutReason, type TokenAnswer } from "./account-core.ts";
import type { GitHubUser, TokenGrant } from "./boundary.ts";
import type { Env } from "./env.ts";
import { keyringOf, oauthAppOf, type PendingSignIn, userIndex } from "./hosted.ts";

/** Each person's safety-net poll, and the refresh that keeps their 6-month refresh token alive. */
export const POLL_MS = 10 * 60_000;

export class UserAccount extends DurableObject<Env> {
  readonly #core: AccountCore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.#core = new AccountCore({
      store: ctx.storage,
      keyring: () => keyringOf(env),
      app: oauthAppOf(env),
      fetch: (input, init) => fetch(input, init),
      now: () => Date.now(),
      onSignedOut: (reason) => this.#signedOut(reason),
    });
  }

  async signIn(user: GitHubUser, grant: TokenGrant, appChallenge: string): Promise<{ handoff: string }> {
    const answer = await this.#core.signIn(user, grant, appChallenge);
    await this.ctx.storage.put("user_id", user.id);
    await this.ctx.storage.setAlarm(Date.now() + POLL_MS);
    return answer;
  }

  finish(handoff: string, verifier: string) {
    return this.#core.finish(handoff, verifier);
  }

  session(fingerprint: string) {
    return this.#core.session(fingerprint);
  }

  accessToken(): Promise<TokenAnswer> {
    return this.#core.accessToken();
  }

  tokenAfterUnauthorized(stale: string): Promise<TokenAnswer> {
    return this.#core.tokenAfterUnauthorized(stale);
  }

  signOutEverywhere(reason: SignedOutReason): Promise<void> {
    return this.#core.signOutEverywhere(reason);
  }

  async signOut(fingerprint: string): Promise<boolean> {
    const isLast = await this.#core.signOut(fingerprint);
    if (isLast) {
      await this.ctx.storage.deleteAlarm();
    }
    return isLast;
  }

  async deleteAccount(): Promise<{ revoked: boolean }> {
    await this.ctx.storage.deleteAlarm();
    return this.#core.deleteAccount();
  }

  /** Every `POLL_MS` while signed in: refresh when due, then the person's index compares with GitHub. */
  override async alarm(): Promise<void> {
    const userId = await this.ctx.storage.get<number>("user_id");
    if (!userId || !(await this.#core.isSignedIn())) {
      return;
    }
    await this.ctx.storage.setAlarm(Date.now() + POLL_MS);
    if ((await this.#core.accessToken()).kind === "ok") {
      await userIndex(this.env, String(userId)).tick(Date.now());
    }
  }

  async #signedOut(reason: SignedOutReason): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    const userId = await this.ctx.storage.get<number>("user_id");
    if (userId) {
      await userIndex(this.env, String(userId)).signedOut(reason);
    }
  }
}

/** A sign-in between `/auth/github/start` and GitHub's callback: taken once, and gone by itself when it expires. */
export class SignIn extends DurableObject<Env> {
  async begin(pending: PendingSignIn): Promise<void> {
    await this.ctx.storage.put("pending", pending);
    await this.ctx.storage.setAlarm(pending.expires_at);
  }

  async take(): Promise<PendingSignIn | null> {
    const pending = await this.ctx.storage.get<PendingSignIn>("pending") ?? null;
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
    return pending;
  }

  override async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}
