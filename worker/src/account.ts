/**
 * The hosted Worker's Durable Objects (docs/api.md, "Hosted sign-in", "Webhook routing", "Limits"): `UserAccount`, one
 * per person named `user:<GitHub user id>`; `SignIn`, one per sign-in in flight named by its state; `Installation`, one
 * per installation of the App named `installation:<id>`; and `IpLimit`, one per client IP named by its hash. Their logic
 * is in `account-core.ts`, `installation-core.ts`, `limit-counter.ts` and `hosted.ts`; these classes only give it
 * storage and alarms.
 */
import { DurableObject } from "cloudflare:workers";
import {
  AccountCore, type AskResources, type SignedOutReason, type TokenAnswer,
} from "./account-core.ts";
import type { GitHubUser, TokenGrant } from "./boundary.ts";
import type { Env } from "./env.ts";
import { canSee, installationOf, keyringOf, oauthAppOf, type PendingSignIn, userIndex } from "./hosted.ts";
import type { RepoFullName } from "./ids.ts";
import { type DeliveryTarget, InstallationCore, isInvolved, type Member, storageStore } from "./installation-core.ts";
import { syncInstallations } from "./installations.ts";
import { consumeLimits, createLimitHitsTable, lastExpiry, type LimitCheck, type LimitDecision } from "./limit-counter.ts";
import { durationOf, LimitName, limitsOf } from "./limits.ts";

/** Each person's safety-net poll, and the refresh that keeps their 6-month refresh token alive. */
function pollMs(env: Env): number {
  return durationOf(limitsOf(env), LimitName.PollIntervalMinutes);
}

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
      limits: limitsOf(env),
      onSignedOut: (reason) => this.#signedOut(reason),
    });
  }

  async signIn(user: GitHubUser, grant: TokenGrant, appChallenge: string): Promise<{ handoff: string }> {
    const answer = await this.#core.signIn(user, grant, appChallenge);
    await this.ctx.storage.put("user_id", user.id);
    await this.ctx.storage.setAlarm(Date.now() + pollMs(this.env));
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

  setAnthropicKey(key: string | null, ask: AskResources | null): Promise<boolean> {
    return this.#core.setAnthropicKey(key, ask);
  }

  installationIds(): Promise<string[]> {
    return this.#core.installationIds();
  }

  claimInstallationSync(now: number, gapMs: number): Promise<boolean> {
    return this.#core.claimInstallationSync(now, gapMs);
  }

  setInstallations(ids: string[], now: number): Promise<void> {
    return this.#core.setInstallations(ids, now);
  }

  /**
   * Every `poll_interval_minutes` while signed in: values sealed with an older key are sealed again, the token is
   * refreshed when due, and the person's index compares with GitHub. Every `installation_sync_hours`, their
   * installations are read again too, so webhooks for repos they gained reach them.
   */
  override async alarm(): Promise<void> {
    const userId = await this.ctx.storage.get<number>("user_id");
    if (!userId || !(await this.#core.isSignedIn())) {
      return;
    }
    await this.ctx.storage.setAlarm(Date.now() + pollMs(this.env));
    const index = userIndex(this.env, String(userId));
    const keys = await this.#core.resealStale();
    if (keys && keys.resealed.length + keys.stale.length > 0) {
      const report = { current: keys.current, resealed: keys.resealed, stale: keys.stale };
      console.log("token_keys", { user_id: userId, ...report });
      await index.record("token_keys", report);
    }
    if ((await this.#core.accessToken()).kind === "ok") {
      await index.tick(Date.now());
      await syncInstallations(this.#core, (id) => installationOf(this.env, id), (input, init) => fetch(input, init),
        Date.now(), durationOf(limitsOf(this.env), LimitName.InstallationSyncHours))
        .catch((error: unknown) => console.error("installation sync failed", error));
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
    // The object may count again before it is evicted.
    createLimitHitsTable(this.ctx.storage.sql);
  }
}

/** Retried this soon when a person's token could not say whether they see a repo. */
const CHECK_RETRY_MS = 15_000;

/** One installation of the App: who sees which of its repos, and the deliveries waiting for a person's token to say. */
export class Installation extends DurableObject<Env> {
  readonly #core: InstallationCore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.#core = new InstallationCore({
      store: storageStore(ctx.storage),
      deliver: (userId, target, login) => deliver(env, userId, target, login),
      dropRepos: async (userId, repos) => {
        await userIndex(env, userId).dropRepos(repos);
      },
      canSee: (userId, repo) => canSee(env, userId, repo),
    });
  }

  join(member: Pick<Member, "user_id" | "login">, repos: string[], account: string | null, now: number) {
    return this.#core.join(member, repos, account, now);
  }

  leave(userId: string) {
    return this.#core.leave(userId);
  }

  reposAdded(repos: string[], now: number) {
    return this.#core.reposAdded(repos, now);
  }

  reposRemoved(repos: string[]) {
    return this.#core.reposRemoved(repos);
  }

  setSuspended(suspended: boolean) {
    return this.#core.setSuspended(suspended);
  }

  async forget(): Promise<string[]> {
    await this.ctx.storage.deleteAlarm();
    return this.#core.forget();
  }

  async route(target: DeliveryTarget, now: number) {
    const routed = await this.#core.route(target, now);
    if (routed.queued.length > 0 && await this.ctx.storage.getAlarm() === null) {
      await this.ctx.storage.setAlarm(Date.now());
    }
    return routed;
  }

  override async alarm(): Promise<void> {
    const { isPending } = await this.#core.runChecks(Date.now());
    if (isPending) {
      await this.ctx.storage.setAlarm(Date.now() + CHECK_RETRY_MS);
    }
  }
}

/** A delivery into one person's index: a PR to read, or the PRs at a head. */
async function deliver(env: Env, userId: string, target: DeliveryTarget, login: string): Promise<void> {
  const index = userIndex(env, userId);
  if (target.kind === "pr") {
    await index.mark(target.repo, target.number, isInvolved(target, login));
  } else {
    await index.markHead(target.repo as RepoFullName, target.sha);
  }
}

/**
 * One client IP's counts toward the per-IP limits (`limit-counter.ts`), named `ip:<SHA-256 of the IP>`. It deletes
 * itself when its last count expires, so no IP's trace outlives the longest window.
 */
export class IpLimit extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    createLimitHitsTable(ctx.storage.sql);
  }

  async consume(checks: LimitCheck[], key: string, now: number): Promise<LimitDecision> {
    const decision = consumeLimits(this.ctx.storage.sql, checks, "", key, now);
    const last = lastExpiry(this.ctx.storage.sql);
    if (last !== null) {
      await this.ctx.storage.setAlarm(last);
    }
    return decision;
  }

  override async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
    // The object may count again before it is evicted.
    createLimitHitsTable(this.ctx.storage.sql);
  }
}
