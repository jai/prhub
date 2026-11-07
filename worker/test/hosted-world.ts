// The hosted Worker's world for tests: a GitHub that answers like the real one for several people, installations and
// repos, and the account, installation and index objects over in-memory stores. No Durable Object, no network.
import assert from "node:assert/strict";
import { AccountCore, type AskResources, type KeyValueStore, type SignedOutReason } from "../src/account-core.ts";
import type { Env } from "../src/env.ts";
import {
  canSeeWith, type HostedServices, type PendingSignIn, publicHostedRoute, type UserIndexApi,
} from "../src/hosted.ts";
import type { RepoFullName, Sha } from "../src/ids.ts";
import { InstallationCore, isInvolved, type ListStore } from "../src/installation-core.ts";
import { consumeLimits, createLimitHitsTable, type LimitSql } from "../src/limit-counter.ts";
import { gitHubReserveOf, limitsOf } from "../src/limits.ts";
import type { OAuthApp } from "../src/oauth.ts";
import { parseKeyring, pkceChallengeOf, randomToken } from "../src/token-crypto.ts";
import { memorySql } from "./memory-sql.ts";

export const env = (vars: Partial<Env>) => vars as Env;
export const keyOf = (fill: number) => Buffer.alloc(32, fill).toString("base64");
export const KEY = `k1:${keyOf(1)}`;
export const APP: OAuthApp = { clientId: "Iv23test", clientSecret: "client-secret" };
export const ORIGIN = "https://prhub.example.workers.dev";
export const HOUR = 3_600_000;

export interface GitHubCall { method: string; url: string; form: URLSearchParams | null; headers: Headers }

export interface FakeUser { id: number; login: string }

export class FakeGitHub {
  calls: GitHubCall[] = [];
  /** The challenge the Worker's authorize URL carried, which the code exchange must match. */
  challenge = "";
  issued = 0;
  liveRefresh = "";
  refusal: string | null = null;
  /** Who the next code exchange signs in. */
  user: FakeUser = { id: 4242, login: "octocat" };
  /** Each access token's person. */
  readonly owners = new Map<string, FakeUser>();
  /** Installations of the App: their account and repos. */
  readonly installations = new Map<number, { account: string; repos: string[] }>();
  /** The repos each person can see, by user id. */
  readonly access = new Map<number, Set<string>>();
  /** Extra headers on every API answer, for rate limits. */
  headers: Record<string, string> = {};

  readonly fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    const method = init?.method ?? "GET";
    const form = typeof init?.body === "string" && url.includes("/login/oauth/") ? new URLSearchParams(init.body) : null;
    const headers = new Headers(init?.headers);
    this.calls.push({ method, url, form, headers });
    if (url === "https://github.com/login/oauth/access_token") {
      if (this.refusal) {
        return Response.json({ error: this.refusal });
      }
      if (form?.get("grant_type") === "refresh_token") {
        return form.get("refresh_token") === this.liveRefresh ? Response.json(this.pair())
          : Response.json({ error: "bad_refresh_token" });
      }
      const isMatch = form?.get("code") === "gh-code"
        && await pkceChallengeOf(form.get("code_verifier") ?? "") === this.challenge;
      return isMatch ? Response.json(this.pair()) : Response.json({ error: "bad_verification_code" });
    }
    if (url.startsWith("https://api.github.com/applications/") && method === "DELETE") {
      return new Response(null, { status: 204 });
    }
    const owner = this.owners.get((headers.get("Authorization") ?? "").replace(/^Bearer /, ""));
    const answer = (body: unknown, status = 200) => Response.json(body, { status, headers: this.headers });
    if (!owner) {
      return answer({ message: "Bad credentials" }, 401);
    }
    const path = new URL(url).pathname;
    // A user token reaches a repo only where the App is installed, and only one the person can see.
    const sees = (repo: string) => (this.access.get(owner.id)?.has(repo.toLowerCase()) ?? false)
      && [...this.installations.values()].some((installation) => installation.repos.includes(repo.toLowerCase()));
    if (path === "/user") {
      return answer(owner);
    }
    if (path === "/user/installations") {
      const page = Number(new URL(url).searchParams.get("page") ?? "1");
      const reached = [...this.installations].filter(([, installation]) => installation.repos.some(sees));
      return answer({
        total_count: reached.length,
        installations: page === 1 ? reached.map(([id, { account }]) => ({ id, account: { login: account } })) : [],
      });
    }
    const repos = /^\/user\/installations\/(\d+)\/repositories$/.exec(path);
    if (repos) {
      const installation = this.installations.get(Number(repos[1]));
      const visible = installation?.repos.filter(sees) ?? [];
      return installation && visible.length > 0
        ? answer({ total_count: visible.length, repositories: visible.map((name) => ({ full_name: name })) })
        : answer({ message: "Not Found" }, 404);
    }
    const repo = /^\/repos\/([^/]+\/[^/]+)$/.exec(path);
    if (repo) {
      return sees(repo[1]) ? answer({ full_name: repo[1] }) : answer({ message: "Not Found" }, 404);
    }
    return answer({ message: "Not Found" }, 404);
  };

  /** A person who can see these repos. */
  grant(user: FakeUser, repos: string[]): void {
    const held = this.access.get(user.id) ?? new Set<string>();
    for (const repo of repos) {
      held.add(repo.toLowerCase());
    }
    this.access.set(user.id, held);
  }

  refreshCalls(): number {
    return this.calls.filter((call) => call.form?.get("grant_type") === "refresh_token").length;
  }

  private pair() {
    this.issued += 1;
    this.liveRefresh = `ghr_${this.issued}`;
    this.owners.set(`ghu_${this.issued}`, this.user);
    return {
      access_token: `ghu_${this.issued}`, expires_in: 28_800, refresh_token: this.liveRefresh,
      refresh_token_expires_in: 15_897_600, scope: "", token_type: "bearer",
    };
  }
}

export class MapStore implements KeyValueStore, ListStore {
  readonly map = new Map<string, unknown>();
  async get<T>(key: string): Promise<T | undefined> {
    return structuredClone(this.map.get(key)) as T | undefined;
  }
  async getMany<T>(keys: string[]): Promise<Map<string, T>> {
    return new Map(keys.filter((key) => this.map.has(key)).map((key) => [key, structuredClone(this.map.get(key)) as T]));
  }
  async put<T>(key: string | Record<string, unknown>, value?: T): Promise<void> {
    const entries = typeof key === "string" ? { [key]: value } : key;
    for (const [name, entry] of Object.entries(entries)) {
      this.map.set(name, structuredClone(entry));
    }
  }
  async delete(keys: string[]): Promise<void> {
    for (const key of keys) {
      this.map.delete(key);
    }
  }
  async list<T>(prefix: string): Promise<Map<string, T>> {
    return new Map([...this.map].filter(([key]) => key.startsWith(prefix)).sort(([a], [b]) => a.localeCompare(b))
      .map(([key, value]) => [key, structuredClone(value) as T]));
  }
  async deleteAll(): Promise<void> {
    this.map.clear();
  }
}

export class FakeIndex implements UserIndexApi {
  calls: string[] = [];
  bindUser(userId: number) { this.calls.push(`bind:${userId}`); }
  tick() { this.calls.push("tick"); }
  mark(repo: RepoFullName, number: number, involved: boolean) { this.calls.push(`mark:${repo}#${number}:${involved}`); }
  markHead(repo: RepoFullName, sha: Sha) { this.calls.push(`head:${repo}@${sha.slice(0, 7)}`); }
  signedOut(reason: SignedOutReason) { this.calls.push(`signed_out:${reason}`); }
  forgetDevices() { this.calls.push("forget_devices"); }
  deleteEverything() { this.calls.push("delete"); }
  dropRepos(repos: string[]) { this.calls.push(`drop:${[...repos].sort().join(",")}`); }
  record(kind: string) { this.calls.push(`event:${kind}`); }
  marks(): string[] {
    return this.calls.filter((call) => call.startsWith("mark:") || call.startsWith("head:"));
  }
}

export const ASK_RESOURCES: AskResources = {
  agent_id: "agent_test", environment_id: "env_test", vault_id: "vault_test", credential_id: "cred_test",
};

export function hostedWorld(vars: Partial<Env> = {}) {
  const github = new FakeGitHub();
  const clock = { now: Date.parse("2026-11-07T00:00:00Z") };
  const stores = new Map<string, MapStore>();
  const accounts = new Map<string, AccountCore>();
  const indexes = new Map<string, FakeIndex>();
  const installationStores = new Map<string, MapStore>();
  const installations = new Map<string, InstallationCore>();
  const pending = new Map<string, PendingSignIn>();
  const deleted: string[] = [];
  const signedOut: SignedOutReason[] = [];
  const ipCounts = new Map<string, LimitSql>();
  const forgottenJobs: string[] = [];
  const anthropic = { valid: new Set<string>(), provisioned: [] as string[] };
  const limits = limitsOf({ HOSTED: "on", ...vars });
  const index = (userId: string) => indexes.get(userId) ?? indexes.set(userId, new FakeIndex()).get(userId) as FakeIndex;
  const account = (userId: string) => {
    if (!accounts.has(userId)) {
      const store = new MapStore();
      stores.set(userId, store);
      accounts.set(userId, new AccountCore({
        store, keyring: () => parseKeyring(KEY), app: APP, fetch: github.fetch,
        now: () => clock.now, limits,
        onSignedOut: async (reason) => {
          signedOut.push(reason);
          await index(userId).signedOut(reason);
        },
      }));
    }
    return accounts.get(userId) as AccountCore;
  };
  const installation = (id: string) => {
    if (!installations.has(id)) {
      const store = new MapStore();
      installationStores.set(id, store);
      installations.set(id, new InstallationCore({
        store,
        deliver: async (userId, target, login) => {
          if (target.kind === "pr") {
            index(userId).mark(target.repo, target.number, isInvolved(target, login));
          } else {
            index(userId).markHead(target.repo, target.sha);
          }
        },
        dropRepos: async (userId, repos) => {
          index(userId).dropRepos(repos);
        },
        canSee: (userId, repo) => canSeeWith(account(userId), repo, github.fetch, clock.now, gitHubReserveOf(limits)),
      }));
    }
    return installations.get(id) as InstallationCore;
  };
  const services: HostedServices = {
    account,
    signIns: {
      begin: async (id, record) => {
        pending.set(id, record);
      },
      take: async (id) => {
        const record = pending.get(id) ?? null;
        pending.delete(id);
        return record;
      },
    },
    index,
    installation,
    deleteStored: async (userId) => {
      deleted.push(userId);
    },
    forgetJobs: async (userId) => {
      forgottenJobs.push(userId);
    },
    limitIp: async (ipHash, checks, key, now) => {
      if (!ipCounts.has(ipHash)) {
        ipCounts.set(ipHash, memorySql());
        createLimitHitsTable(ipCounts.get(ipHash) as LimitSql);
      }
      return consumeLimits(ipCounts.get(ipHash) as LimitSql, checks, "", key, now);
    },
    limits,
    anthropic: {
      check: async (key) => anthropic.valid.has(key) ? "ok" : "invalid",
      provisionAsk: async (key) => {
        anthropic.provisioned.push(key);
        return ASK_RESOURCES;
      },
    },
    fetch: github.fetch,
    now: () => clock.now,
  };
  const workerEnv = env({
    HOSTED: "on", GITHUB_APP_CLIENT_ID: APP.clientId, GITHUB_APP_CLIENT_SECRET: APP.clientSecret,
    TOKEN_ENCRYPTION_KEY: KEY, WEBHOOK_SECRET: "hook-secret", APPLE_APP_ID: "TEAMID.com.example.prhub",
    ANTHROPIC_API_KEY: "operator-anthropic-key", USER_ACCOUNTS: {} as Env["USER_ACCOUNTS"],
    SIGN_INS: {} as Env["SIGN_INS"], INSTALLATIONS: {} as Env["INSTALLATIONS"], IP_LIMITS: {} as Env["IP_LIMITS"],
    ...vars,
  });
  const waited: Promise<unknown>[] = [];
  const route = async (path: string, init: RequestInit = {}) => {
    const answer = publicHostedRoute(new Request(`${ORIGIN}${path}`, init), workerEnv, services, APP,
      (promise) => waited.push(promise));
    assert.ok(answer, `${path} is a hosted route`);
    return answer;
  };
  return {
    github, clock, stores, accounts, indexes, installations, installationStores, pending, deleted, signedOut, ipCounts,
    forgottenJobs, anthropic, services, workerEnv, route, waited,
  };
}

export type World = ReturnType<typeof hostedWorld>;

export const APP_STATE = "app-state-0123456789";
export const APP_VERIFIER = "v".repeat(20) + randomToken();

export async function startSignIn(world: World, verifier = APP_VERIFIER): Promise<URL> {
  const challenge = await pkceChallengeOf(verifier);
  const start = await world.route(`/auth/github/start?${new URLSearchParams({
    state: APP_STATE, code_challenge: challenge, code_challenge_method: "S256",
  })}`);
  assert.equal(start.status, 302);
  const authorize = new URL(start.headers.get("Location") ?? "");
  world.github.challenge = authorize.searchParams.get("code_challenge") ?? "";
  return authorize;
}

export async function callback(world: World, params: Record<string, string>): Promise<URL> {
  const answer = await world.route(`/auth/github/callback?${new URLSearchParams(params)}`);
  assert.equal(answer.status, 302);
  return new URL(answer.headers.get("Location") ?? "");
}

/** Start, GitHub's callback and the app's finish, as `user` (the world's default person when omitted): the session. */
export async function signIn(world: World, user?: FakeUser): Promise<string> {
  if (user) {
    world.github.user = user;
  }
  const authorize = await startSignIn(world);
  const done = await callback(world, { code: "gh-code", state: authorize.searchParams.get("state") ?? "" });
  const finish = await world.route("/auth/github/finish", {
    method: "POST", body: JSON.stringify({ code: done.searchParams.get("code"), code_verifier: APP_VERIFIER }),
  });
  assert.equal(finish.status, 200);
  const { secret } = await finish.json() as { secret: string };
  await Promise.all(world.waited.splice(0));
  return secret;
}

export const bearer = (secret: string) => ({ headers: { Authorization: `Bearer ${secret}` } });

/** A delivery as GitHub signs it with the webhook secret. */
export async function deliver(world: World, event: string, payload: object, secret = "hook-secret"): Promise<Response> {
  const body = JSON.stringify(payload);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" },
    false, ["sign"]);
  const signature = Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))).toString("hex");
  const answer = await world.route("/github/webhook", {
    method: "POST", body, headers: { "X-GitHub-Event": event, "X-Hub-Signature-256": `sha256=${signature}` },
  });
  await Promise.all(world.waited.splice(0));
  return answer;
}
