/**
 * Hosted mode (docs/api.md, "Hosted sign-in"; docs/plans/github-app.md): one Worker serves everyone through the PRHub
 * GitHub App. A person signs in with GitHub, and every read and write for them goes with their own user access token.
 * Off unless `HOSTED` is `on`; a self-hosted Worker never reaches anything here.
 */
import type {
  AccountCore, AskResources, SessionInfo, SignedOutReason, TokenAnswer, UserAi,
} from "./account-core.ts";
import { isAnthropicKeyShape, NO_AI, userIdOf } from "./account-core.ts";
import { bodyOf, parseFinishInput, parseSender } from "./boundary.ts";
import { askQueueName, type Env, isSet } from "./env.ts";
import type { Fingerprint, RepoFullName, Sha } from "./ids.ts";
import {
  type InstallationAccount, type InstallationApi, parseAppDelivery, syncInstallations,
} from "./installations.ts";
import type { LimitCheck, LimitDecision } from "./limit-counter.ts";
import {
  durationOf, gitHubReserveOf, type GitHubReserve, LimitName, limitReachedAnswer, type Limits, limitsOf, rateWindowOf,
  type RateLimitName, readNowGapOf,
} from "./limits.ts";
import { authorizeUrl, exchangeCode, type Fetch, type OAuthApp, readUser } from "./oauth.ts";
import { deviceSecretOf, fingerprintOf, sha256Hex } from "./pairing.ts";
import { backoffOf } from "./rate-limit.ts";
import {
  isPkceChallenge, type Keyring, parseKeyring, pkceChallengeOf, randomToken,
} from "./token-crypto.ts";
import { verifySignature } from "./webhook.ts";
import { checkAnthropicKey, createAskResources } from "./ask-setup.ts";
import { onApiKey } from "./agent-container.ts";
import type { IpLimit } from "./account.ts";

export type HostedMode = { kind: "off" } | { kind: "on"; app: OAuthApp } | { kind: "misconfigured"; missing: string[] };

/** On with `HOSTED=on` and everything sign-in needs; `HOSTED=on` without it serves nothing rather than fall back. */
export function hostedMode(env: Env): HostedMode {
  if (env.HOSTED?.trim() !== "on") {
    return { kind: "off" };
  }
  const missing = [
    ["GITHUB_APP_CLIENT_ID", isSet(env.GITHUB_APP_CLIENT_ID)],
    ["GITHUB_APP_CLIENT_SECRET", isSet(env.GITHUB_APP_CLIENT_SECRET)],
    ["TOKEN_ENCRYPTION_KEY", isSet(env.TOKEN_ENCRYPTION_KEY)],
    ["USER_ACCOUNTS", env.USER_ACCOUNTS !== undefined],
    ["SIGN_INS", env.SIGN_INS !== undefined],
    ["INSTALLATIONS", env.INSTALLATIONS !== undefined],
    ["IP_LIMITS", env.IP_LIMITS !== undefined],
  ].flatMap(([name, isThere]) => isThere ? [] : [name as string]);
  return missing.length > 0 ? { kind: "misconfigured", missing } : { kind: "on", app: oauthAppOf(env) };
}

export function oauthAppOf(env: Env): OAuthApp {
  return { clientId: env.GITHUB_APP_CLIENT_ID ?? "", clientSecret: env.GITHUB_APP_CLIENT_SECRET ?? "" };
}

let parsedKeyring: { raw: string; keyring: Promise<Keyring | null> } | null = null;

/** `TOKEN_ENCRYPTION_KEY`, parsed once per isolate and per value. */
export function keyringOf(env: Env): Promise<Keyring | null> {
  const raw = env.TOKEN_ENCRYPTION_KEY ?? "";
  if (parsedKeyring?.raw !== raw) {
    parsedKeyring = { raw, keyring: parseKeyring(raw) };
  }
  return parsedKeyring.keyring;
}

/** Whether the Worker can mint installation tokens: the App's id and private key. Ask on the hosted Worker needs it. */
export function canMintInstallationTokens(env: Env): boolean {
  return isSet(env.GITHUB_APP_ID) && isSet(env.GITHUB_APP_PRIVATE_KEY);
}

/**
 * The Worker as it acts for one signed-in person: their token and login, their objects (`user:<id>`), their R2 prefix.
 * AI runs on the person's own Anthropic key: key lines and rewrites once they gave it, Ask once Ask's resources
 * exist in their org and the Worker can mint installation tokens. Key lines and rewrites run on the Worker's
 * subscription only for `SUBSCRIPTION_LOGINS`. Never on the Worker's own key, and Feedback, the
 * relay and Linear, which serve only Jai, stay off.
 */
export function userEnv(env: Env, user: { userId: string; login: string; token: string; ai?: UserAi }): Env {
  const ai = user.ai ?? NO_AI;
  const ask = ai.anthropicKey !== null && canMintInstallationTokens(env) ? ai.ask : null;
  return {
    ...env,
    GITHUB_TOKEN: user.token,
    GITHUB_LOGIN: user.login,
    SIGNED_IN_USER_ID: user.userId,
    GITHUB_ORGS: undefined,
    APP_TOKEN: undefined,
    HUB_TOKEN: undefined,
    WEBHOOK_SECRET: undefined,
    ANTHROPIC_API_KEY: ai.anthropicKey ?? undefined,
    CLAUDE_CODE_OAUTH_TOKEN: subscriptionLogins(env).has(user.login.toLowerCase()) ? env.CLAUDE_CODE_OAUTH_TOKEN : undefined,
    ASK_ANTHROPIC_API_KEY: undefined,
    ASK_AGENT_ID: ask?.agent_id,
    ASK_ENVIRONMENT_ID: ask?.environment_id,
    ASK_VAULT_ID: ask?.vault_id,
    ASK_CREDENTIAL_ID: ask?.credential_id,
    ASK_GITHUB_APP_ID: undefined,
    ASK_GITHUB_APP_KEY: undefined,
    ASK_GITHUB_TOKEN: undefined,
    FEEDBACK_REPO: undefined,
    AGENT_PAGER_URL: undefined,
    LINEAR_API_KEY: undefined,
    GITHUB_RATE: undefined,
  };
}

/** The logins whose AI runs on the Worker's subscription (`SUBSCRIPTION_LOGINS`), lowercased. */
function subscriptionLogins(env: Env): Set<string> {
  return new Set((env.SUBSCRIPTION_LOGINS ?? "").split(",").map((login) => login.trim().toLowerCase()).filter(Boolean));
}

/** What the routes reach: the Durable Objects, R2 and GitHub, so a test can stand in for each. */
export interface HostedServices {
  account(userId: string): AccountApi;
  signIns: {
    begin(id: string, pending: PendingSignIn): Promise<void>;
    take(id: string): Promise<PendingSignIn | null>;
  };
  index(userId: string): UserIndexApi;
  installation(id: string): InstallationApi;
  /** Deletes the person's R2 objects (`users/<id>/`). */
  deleteStored(userId: string): Promise<void>;
  /** Drops the person's queued AI jobs, so none runs, or stores an answer, after Delete Account. */
  forgetJobs(userId: string): Promise<void>;
  /** One request against a client IP's counts (`IpLimit`); `ipHash` is the SHA-256 of the IP, never the IP. */
  limitIp(ipHash: string, checks: LimitCheck[], key: string, now: number): Promise<LimitDecision>;
  limits: Limits;
  anthropic: AnthropicApi;
  fetch: Fetch;
  now(): number;
}

/** Anthropic, for a person's own key: whether it works, and Ask's resources made in their org (`ask-setup.ts`). */
export interface AnthropicApi {
  check(key: string): Promise<"ok" | "invalid" | "unavailable">;
  provisionAsk(key: string, login: string): Promise<AskResources>;
}

export type AccountApi = Pick<AccountCore,
  "signIn" | "finish" | "session" | "accessToken" | "tokenAfterUnauthorized" | "signOutEverywhere" | "signOut"
  | "deleteAccount" | "setAnthropicKey" | "installationIds" | "claimInstallationSync" | "setInstallations"
  | "installationAccounts" | "installationSyncedAt">;

/** The part of a person's `PrIndex` the hosted routes and installations touch. */
export interface UserIndexApi {
  bindUser(userId: number): unknown;
  tick(now: number): unknown;
  mark(repo: RepoFullName, number: number, involved: boolean): unknown;
  markHead(repo: RepoFullName, sha: Sha): unknown;
  signedOut(reason: SignedOutReason): unknown;
  forgetDevices(): unknown;
  forgetPushRegistrationsOf(fingerprint: Fingerprint): unknown;
  prunePushRegistrationsOnce(live: string[]): unknown;
  deleteEverything(): unknown;
  dropRepos(repos: string[]): unknown;
  record(kind: string, detail: Record<string, unknown>): unknown;
}

/** Kept by `SignIn` from start to callback. The app's state and challenge go back to it; the verifier never leaves. */
export interface PendingSignIn {
  app_state: string;
  app_challenge: string;
  github_verifier: string;
  redirect_uri: string;
  expires_at: number;
}

export function userObjectName(userId: string): string {
  return `user:${userId}`;
}

/** A person's PR index, named as their account is. */
export function userIndex(env: Env, userId: string): DurableObjectStub & UserIndexApi {
  const stub = env.PR_INDEX.get(env.PR_INDEX.idFromName(userObjectName(userId)));
  return stub as unknown as DurableObjectStub & UserIndexApi;
}

export function accountOf(env: Env, userId: string): AccountApi {
  const namespace = env.USER_ACCOUNTS as DurableObjectNamespace;
  return namespace.get(namespace.idFromName(userObjectName(userId))) as unknown as AccountApi;
}

/** An installation's object, named `installation:<id>`. */
export function installationOf(env: Env, id: string): InstallationApi {
  const namespace = env.INSTALLATIONS as DurableObjectNamespace;
  return namespace.get(namespace.idFromName(`installation:${id}`)) as unknown as InstallationApi;
}

/**
 * Whether the person's own token can read the repo: `GET /repos/{repo}`. False for no (404, 403) and for a signed-out
 * person; null when GitHub could not say (down, or asking the token to wait), so the question is asked again.
 */
export async function canSeeWith(
  account: Pick<AccountApi, "accessToken">, repo: RepoFullName, fetcher: Fetch, now: number, reserve: GitHubReserve,
): Promise<boolean | null> {
  const answer = await account.accessToken();
  if (answer.kind !== "ok") {
    return answer.kind === "signed_out" ? false : null;
  }
  let response: Response;
  try {
    response = await fetcher(`https://api.github.com/repos/${repo}`, {
      headers: { Accept: "application/vnd.github+json", Authorization: `Bearer ${answer.token}`, "User-Agent": "pr-viewer" },
    });
  } catch {
    return null;
  }
  const backoff = backoffOf(response, now, reserve);
  if (backoff && backoff.kind !== "low" && !response.ok) {
    return null;
  }
  if (response.ok) {
    return true;
  }
  return response.status === 404 || response.status === 403 ? false : null;
}

export function canSee(env: Env, userId: string, repo: RepoFullName): Promise<boolean | null> {
  return canSeeWith(accountOf(env, userId), repo, (input, init) => fetch(input, init), Date.now(),
    gitHubReserveOf(limitsOf(env)));
}

/** The real services: the Worker's bindings. */
export function servicesOf(env: Env): HostedServices {
  const signIn = (id: string) => {
    const namespace = env.SIGN_INS as DurableObjectNamespace;
    return namespace.get(namespace.idFromName(`signin:${id}`)) as unknown as {
      begin(pending: PendingSignIn): Promise<void>; take(): Promise<PendingSignIn | null>;
    };
  };
  return {
    account: (userId) => accountOf(env, userId),
    signIns: { begin: (id, pending) => signIn(id).begin(pending), take: (id) => signIn(id).take() },
    index: (userId) => userIndex(env, userId),
    installation: (id) => installationOf(env, id),
    deleteStored: (userId) => deletePrefix(env.DIFFS, `users/${userId}/`),
    forgetJobs: async (userId) => {
      const name = userObjectName(userId);
      await env.AI_JOBS.get(env.AI_JOBS.idFromName(name)).forget();
      await env.AI_JOBS.get(env.AI_JOBS.idFromName(askQueueName(name))).forget();
    },
    limitIp: (ipHash, checks, key, now) => {
      const namespace = env.IP_LIMITS as DurableObjectNamespace<IpLimit>;
      return namespace.get(namespace.idFromName(`ip:${ipHash}`)).consume(checks, key, now);
    },
    limits: limitsOf(env),
    anthropic: { check: checkAnthropicKey, provisionAsk: createAskResources },
    fetch: (input, init) => fetch(input, init),
    now: () => Date.now(),
  };
}

async function deletePrefix(bucket: R2Bucket, prefix: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const listed = await bucket.list({ prefix, cursor, limit: 1_000 });
    if (listed.objects.length > 0) {
      await bucket.delete(listed.objects.map((object) => object.key));
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
}

/**
 * GitHub answered 401 to a person's token: the account refreshes it (once, whatever else asks at the same time) and
 * the request goes again with the new one. Null when there is none: the person is signed out, or GitHub is away.
 */
export async function renewAfterUnauthorized(env: Env): Promise<string | null> {
  if (!isSet(env.SIGNED_IN_USER_ID) || env.USER_ACCOUNTS === undefined) {
    return null;
  }
  const answer = await accountOf(env, env.SIGNED_IN_USER_ID).tokenAfterUnauthorized(env.GITHUB_TOKEN);
  if (answer.kind !== "ok") {
    return null;
  }
  env.GITHUB_TOKEN = answer.token;
  return answer.token;
}

/** For a person's `PrIndex` working on its own (alarm, poll): the Worker as it acts for them, or null when it can't. */
export async function actingEnvFor(env: Env, userId: string): Promise<Env | null> {
  const answer: TokenAnswer = await accountOf(env, userId).accessToken();
  return answer.kind === "ok" ? userEnv(env, answer) : null;
}

// --- Routes ---------------------------------------------------------------------------------------------------------

const APP_STATE = /^[A-Za-z0-9._~-]{16,256}$/;
const SIGN_IN_ID = /^[A-Za-z0-9_-]{43}$/;

function errorAnswer(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status, headers: { "Cache-Control": "no-store" } });
}

function page(title: string, text: string, status = 200, link?: { href: string; label: string }): Response {
  const button = link ? `<p><a href="${link.href}" style="font-size:20px">${link.label}</a></p>` : "";
  return new Response(`<!doctype html><meta name="viewport" content="width=device-width"><title>${title}</title>
    <body style="font-family:-apple-system,sans-serif;padding:24px"><h1>${title}</h1><p>${text}</p>${button}</body>`,
  { status, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });
}

/** Where the app's authentication session ends: the app catches it and never loads it. */
function doneUrl(origin: string, fields: Record<string, string>): string {
  return `${origin}/auth/github/done?${new URLSearchParams(fields)}`;
}

/**
 * `GET /auth/github/start?state&code_challenge&code_challenge_method=S256`: opened by the app's authentication session.
 * The Worker keeps the app's state and challenge under a state of its own, and sends GitHub a challenge of its own
 * too: GitHub's code is traded here, with a verifier that never leaves the Worker.
 */
export async function startRoute(request: Request, services: HostedServices, app: OAuthApp): Promise<Response> {
  const url = new URL(request.url);
  const appState = url.searchParams.get("state") ?? "";
  const appChallenge = url.searchParams.get("code_challenge");
  if (!APP_STATE.test(appState) || !isPkceChallenge(appChallenge)
    || url.searchParams.get("code_challenge_method") !== "S256") {
    return errorAnswer(400, "validation_error",
      "state must be 16-256 URL-safe characters, code_challenge an S256 challenge, code_challenge_method S256");
  }
  const id = randomToken();
  const githubVerifier = randomToken();
  const redirectUri = `${url.origin}/auth/github/callback`;
  await services.signIns.begin(id, {
    app_state: appState, app_challenge: appChallenge, github_verifier: githubVerifier, redirect_uri: redirectUri,
    expires_at: services.now() + durationOf(services.limits, LimitName.SignInMinutes),
  });
  return new Response(null, {
    status: 302,
    headers: {
      Location: authorizeUrl(app, redirectUri, id, await pkceChallengeOf(githubVerifier)),
      "Cache-Control": "no-store",
    },
  });
}

/**
 * `GET /auth/github/callback`: GitHub sends the browser here. With a sign-in in flight, the Worker trades the code,
 * reads who it is, keeps their tokens, and sends the browser on to `/auth/github/done` with a one-time code for the
 * app.
 * Without one (`request_oauth_on_install`, from an install on github.com), a page: nothing is traded.
 */
export async function callbackRoute(
  request: Request, services: HostedServices, app: OAuthApp, waitUntil: (promise: Promise<unknown>) => void,
): Promise<Response> {
  const url = new URL(request.url);
  const params = url.searchParams;
  const id = params.get("state");
  if (id === null) {
    return page("PRHub is installed", "Open PRHub on your iPhone and sign in with GitHub to see your pull requests.",
      200, { href: "prhub://", label: "Open PRHub" });
  }
  const pending = SIGN_IN_ID.test(id) ? await services.signIns.take(id) : null;
  if (!pending || pending.expires_at <= services.now()) {
    return Response.redirect(doneUrl(url.origin, { error: "sign_in_expired" }), 302);
  }
  const fail = (error: string) => Response.redirect(doneUrl(url.origin, { error, state: pending.app_state }), 302);
  if (params.has("error")) {
    return fail(params.get("error") === "access_denied" ? "access_denied" : "github_refused");
  }
  const code = params.get("code");
  if (!code || code.length > 200) {
    return fail("github_refused");
  }
  const outcome = await exchangeCode(app, code, pending.github_verifier, pending.redirect_uri, services.fetch);
  if (outcome.kind !== "granted") {
    console.error("sign-in: code exchange failed", outcome.kind === "refused" ? outcome.error : outcome.status);
    return fail(outcome.kind === "refused" ? "github_refused" : "github_unavailable");
  }
  const user = await readUser(outcome.grant.access_token, services.fetch);
  if (!user) {
    return fail("github_unavailable");
  }
  const userId = String(user.id);
  const { handoff } = await services.account(userId).signIn(user, outcome.grant, pending.app_challenge);
  const index = services.index(userId);
  waitUntil((async () => {
    await index.bindUser(user.id);
    await syncInstallations(services.account(userId), services.installation, services.fetch, services.now(), 0);
    await index.tick(services.now());
  })().catch((error: unknown) => console.error("sign-in: first sync failed", error)));
  return Response.redirect(doneUrl(url.origin, { code: handoff, state: pending.app_state }), 302);
}

/** `GET /auth/github/done`: only a browser outside the app gets this far. */
export function doneRoute(): Response {
  return page("Back to PRHub", "Return to PRHub to finish signing in.");
}

/** `POST /auth/github/finish`: the one-time code and the app's PKCE verifier, for the session secret. */
export async function finishRoute(request: Request, services: HostedServices): Promise<Response> {
  const input = parseFinishInput((await bodyOf(request))?.value);
  const userId = userIdOf(input?.code ?? null);
  if (!input || !userId) {
    return errorAnswer(400, "validation_error", "code must be the callback's code; code_verifier the PKCE verifier");
  }
  const session = await services.account(userId).finish(input.code, input.code_verifier);
  if (!session) {
    return errorAnswer(401, "sign_in_invalid", "unknown, used or expired code, or a verifier that does not match");
  }
  return Response.json({ secret: session.secret, login: session.login, user_id: session.userId },
    { headers: { "Cache-Control": "no-store" } });
}

/** A request's session: whose it is, and its fingerprint. Null when the bearer is no session this Worker minted. */
export async function sessionOf(
  request: Request, services: HostedServices,
): Promise<(SessionInfo & { fingerprint: Fingerprint }) | null> {
  const secret = deviceSecretOf(request.headers.get("Authorization"));
  const userId = userIdOf(secret);
  if (!secret || !userId) {
    return null;
  }
  const fingerprint = await fingerprintOf(secret);
  const session = await services.account(userId).session(fingerprint);
  return session && { ...session, fingerprint };
}

/**
 * `POST /auth/signout`: this phone's session ends, and its push registrations go. The last phone out takes the tokens
 * and every push registration along.
 */
export async function signOutRoute(request: Request, services: HostedServices): Promise<Response> {
  const session = await sessionOf(request, services);
  if (!session) {
    return errorAnswer(401, "unauthorized", "send the session secret as the bearer");
  }
  const index = services.index(session.userId);
  if (await services.account(session.userId).signOut(session.fingerprint)) {
    await index.forgetDevices();
  } else {
    await index.forgetPushRegistrationsOf(session.fingerprint);
  }
  return new Response(null, { status: 204 });
}

/**
 * `DELETE /account` (App Review 5.1.1(v)): GitHub revokes PRHub's authorization and tokens for this person, and the
 * Worker deletes their account, PR index and stored PR content.
 */
export async function deleteAccountRoute(request: Request, services: HostedServices): Promise<Response> {
  const session = await sessionOf(request, services);
  if (!session) {
    return errorAnswer(401, "unauthorized", "send the session secret as the bearer");
  }
  const account = services.account(session.userId);
  const installations = await account.installationIds();
  const { revoked } = await account.deleteAccount();
  await services.forgetJobs(session.userId);
  // Out of every installation first-hand, so no delivery reaches the index being deleted, or makes it again.
  for (const id of installations) {
    await services.installation(id).leave(session.userId);
  }
  await services.index(session.userId).deleteEverything();
  await services.deleteStored(session.userId);
  return Response.json({ deleted: true, github_revoked: revoked }, { headers: { "Cache-Control": "no-store" } });
}

/**
 * `POST /github/webhook` on the hosted Worker (docs/api.md, "Webhook routing"). `github_app_authorization` `revoked`
 * signs the person out everywhere. `installation` and `installation_repositories` keep each installation's repos and
 * suspension, and send the person who acted, whatever they did, to read their installations again. Pull request, comment, check suite and
 * status events go to the installation, which marks them in the index of each member who can see the repo.
 */
export async function hostedWebhook(
  request: Request, env: Env, services: HostedServices, waitUntil: (promise: Promise<unknown>) => void,
): Promise<Response> {
  if (!isSet(env.WEBHOOK_SECRET)) {
    return new Response("not found\n", { status: 404 });
  }
  const body = await request.arrayBuffer();
  if (!(await verifySignature(body, request.headers.get("X-Hub-Signature-256"), env.WEBHOOK_SECRET))) {
    return new Response("unauthenticated\n", { status: 401 });
  }
  const event = request.headers.get("X-GitHub-Event");
  let payload: unknown = null;
  try {
    payload = JSON.parse(new TextDecoder().decode(body));
  } catch {
    // Not JSON: nothing to act on.
  }
  if (event === "github_app_authorization") {
    const delivery = parseSender(payload);
    if (delivery?.action === "revoked") {
      await services.account(String(delivery.sender.id)).signOutEverywhere("revoked");
    }
    return new Response(null, { status: 202 });
  }
  const delivery = parseAppDelivery(event, payload);
  if (!delivery) {
    return new Response(null, { status: 202 });
  }
  const installation = services.installation(delivery.installationId);
  const now = services.now();
  const syncSender = (senderId: number | null) => {
    if (senderId !== null) {
      waitUntil(syncInstallations(services.account(String(senderId)), services.installation, services.fetch, now, 0)
        .catch((error: unknown) => console.error("installation sync failed", error)));
    }
  };
  if (delivery.kind === "target") {
    await installation.route(delivery.target, now);
    return new Response(null, { status: 202 });
  }
  if (delivery.kind === "installation_repositories") {
    if (delivery.removed.length > 0) {
      await installation.reposRemoved(delivery.removed);
    }
    if (delivery.added.length > 0) {
      await installation.reposAdded(delivery.added, now);
    }
  } else if (delivery.action === "deleted") {
    await installation.forget();
  } else if (delivery.action === "suspend") {
    await installation.setSuspended(true);
  } else {
    if (delivery.action === "unsuspend") {
      await installation.setSuspended(false);
    }
    await installation.reposAdded(delivery.repos, now);
  }
  // Whoever acted reads their installations again, so their app's list is current when they come back from GitHub.
  syncSender(delivery.senderId);
  return new Response(null, { status: 202 });
}

/**
 * `PUT /account/anthropic-key` with `{"key": "…"}`, and `DELETE /account/anthropic-key`: the person's own Anthropic key,
 * on which their key lines, rewrites and Ask run. Anthropic must accept it first; Ask's agent, environment and vault are
 * then made in their org when this Worker can serve Ask. Sealed at rest, never answered back.
 */
export async function anthropicKeyRoute(request: Request, env: Env, services: HostedServices): Promise<Response> {
  const session = await sessionOf(request, services);
  if (!session) {
    return errorAnswer(401, "unauthorized", "sign in with GitHub");
  }
  if (session.state !== "signed_in") {
    return errorAnswer(401, "signed_out", "sign in with GitHub again");
  }
  const account = services.account(session.userId);
  if (request.method === "DELETE") {
    await account.setAnthropicKey(null, null);
    return new Response(null, { status: 204 });
  }
  if (!onApiKey(env)) {
    return errorAnswer(409, "api_key_off", "AI runs on the subscription for now, so a key can't be added");
  }
  const body = (await bodyOf(request))?.value as { key?: unknown } | undefined;
  const key = typeof body?.key === "string" ? body.key.trim() : null;
  if (!isAnthropicKeyShape(key)) {
    return errorAnswer(400, "validation_error", "key must be an Anthropic API key");
  }
  const checked = await services.anthropic.check(key);
  if (checked !== "ok") {
    return checked === "invalid" ? errorAnswer(422, "anthropic_key_invalid", "Anthropic did not accept this key")
      : errorAnswer(503, "anthropic_unavailable", "Anthropic could not be asked; try again");
  }
  let ask: AskResources | null = null;
  if (canMintInstallationTokens(env)) {
    try {
      ask = await services.anthropic.provisionAsk(key, session.login);
    } catch (error) {
      // The key works for key lines and rewrites; Ask stays off until it is given again.
      console.error("Ask setup failed", error instanceof Error ? error.name : "unknown");
    }
  }
  if (!(await account.setAnthropicKey(key, ask))) {
    return errorAnswer(401, "signed_out", "sign in with GitHub again");
  }
  return Response.json({ anthropic_key: true, ask_ai: ask !== null }, { headers: { "Cache-Control": "no-store" } });
}

/** Sign-in routes a client may call at will, limited per IP: `429 limit_reached` past the limit. */
async function limited(request: Request, services: HostedServices, name: RateLimitName): Promise<Response | null> {
  const window = rateWindowOf(services.limits, name);
  if (!window) {
    return null;
  }
  const ipHash = await sha256Hex(request.headers.get("CF-Connecting-IP") ?? "unknown");
  const decision = await services.limitIp(ipHash, [{ name, window }], randomToken(), services.now());
  return decision.allowed ? null : limitReachedAnswer(decision.name, decision.retryAfterMs);
}

/** `/.well-known/apple-app-site-association`: lets the app catch `/auth/github/done` as its HTTPS callback. */
export function associationRoute(env: Env): Response {
  if (!isSet(env.APPLE_APP_ID)) {
    return new Response("not found\n", { status: 404 });
  }
  return Response.json({ webcredentials: { apps: [env.APPLE_APP_ID.trim()] } });
}

/**
 * Everything hosted mode answers before a session is needed, or null for a route that needs one. Self-hosted routes
 * that act with the Worker's own token (pairing, the webhook App's setup, the hub's states) are not served.
 */
export function publicHostedRoute(
  request: Request, env: Env, services: HostedServices, app: OAuthApp, waitUntil: (promise: Promise<unknown>) => void,
): Promise<Response> | null {
  const { pathname } = new URL(request.url);
  const limit = pathname === "/auth/github/start" && request.method === "GET" ? LimitName.SignInStartsPerIpPerMinute
    : pathname === "/auth/github/finish" && request.method === "POST" ? LimitName.SignInFinishesPerIpPerMinute : null;
  if (limit) {
    return limited(request, services, limit)
      .then((answer) => answer ?? openRoute(request, env, services, app, waitUntil) as Promise<Response>);
  }
  return openRoute(request, env, services, app, waitUntil);
}

function openRoute(
  request: Request, env: Env, services: HostedServices, app: OAuthApp, waitUntil: (promise: Promise<unknown>) => void,
): Promise<Response> | null {
  const { pathname } = new URL(request.url);
  const method = request.method;
  if (pathname === "/.well-known/apple-app-site-association" && method === "GET") {
    return Promise.resolve(associationRoute(env));
  }
  if (pathname === "/auth/github/start" && method === "GET") {
    return startRoute(request, services, app);
  }
  if (pathname === "/auth/github/callback" && method === "GET") {
    return callbackRoute(request, services, app, waitUntil);
  }
  if (pathname === "/auth/github/done" && method === "GET") {
    return Promise.resolve(doneRoute());
  }
  if (pathname === "/auth/github/finish" && method === "POST") {
    return finishRoute(request, services);
  }
  if (pathname === "/auth/signout" && method === "POST") {
    return signOutRoute(request, services);
  }
  if (pathname === "/account" && method === "DELETE") {
    return deleteAccountRoute(request, services);
  }
  if (pathname === "/github/webhook" && method === "POST") {
    return hostedWebhook(request, env, services, waitUntil);
  }
  if (pathname === "/account/anthropic-key" && (method === "PUT" || method === "DELETE")) {
    return anthropicKeyRoute(request, env, services);
  }
  if (["/device/pair", "/github/setup", "/github/callback", "/github/app-credentials", "/prs/states"]
    .includes(pathname)) {
    return Promise.resolve(new Response("not found\n", { status: 404 }));
  }
  return null;
}

/**
 * The Worker as it acts for the request's signed-in person, or the answer when it can't: `401 unauthorized` for no
 * session, `401 signed_out` for one whose tokens GitHub no longer honours, `503` when GitHub can't be asked.
 * `/device/config` is answered for a signed-out session too, so the app can show Sign in again.
 */
export async function authenticate(
  request: Request, env: Env, services: HostedServices,
): Promise<{ env: Env; session: SessionInfo } | { answer: Response; session: SessionInfo | null }> {
  const session = await sessionOf(request, services);
  if (!session) {
    return { answer: errorAnswer(401, "unauthorized", "sign in with GitHub"), session: null };
  }
  const token = session.state === "signed_in" ? await services.account(session.userId).accessToken()
    : { kind: "signed_out" as const };
  if (token.kind === "ok") {
    return { env: userEnv(env, token), session };
  }
  return token.kind === "signed_out"
    ? { answer: errorAnswer(401, "signed_out", "sign in with GitHub again"), session }
    : { answer: errorAnswer(503, "github_unavailable", "GitHub could not be asked; try again"), session };
}

/** How long `GET /device/config` waits for a read of the installations before it answers with the ones it holds. */
const READ_NOW_WAIT_MS = 8_000;

/**
 * The installations `GET /device/config` answers with (docs/api.md, "Hosted sign-in"). GitHub is read before the
 * answer when the app would otherwise show a list that may be wrong: the first config of a new session, a list that is
 * empty or not read yet, and `?fresh=1`, which the app sends back from GitHub's install pages. Those reads are spaced
 * by `installation_reads_now_per_minute`, except a new session's first. Any other open reads GitHub after answering,
 * once the last read is `installation_sync_on_open_minutes` old.
 */
export async function configInstallations(
  request: Request, session: SessionInfo, services: HostedServices, waitUntil: (promise: Promise<unknown>) => void,
): Promise<InstallationAccount[] | null> {
  const account = services.account(session.userId);
  const held = await account.installationAccounts();
  const isNewSession = await account.installationSyncedAt() < session.createdAt;
  const readsNow = isNewSession || !held?.length || new URL(request.url).searchParams.get("fresh") === "1";
  const gapMs = isNewSession ? 0
    : readsNow ? readNowGapOf(services.limits) : durationOf(services.limits, LimitName.InstallationSyncOnOpenMinutes);
  const sync = syncInstallations(account, services.installation, services.fetch, services.now(), gapMs)
    .catch((error: unknown) => console.error("installation sync failed", error));
  waitUntil(sync);
  if (!readsNow) {
    return held;
  }
  await new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, READ_NOW_WAIT_MS);
    void sync.finally(() => {
      clearTimeout(timer);
      resolve();
    });
  });
  return account.installationAccounts();
}

/**
 * What `GET /device/config` adds on the hosted Worker. Whether a key is set, never the key. `installations` once a sync
 * has read them for a signed-in person.
 */
export function hostedAccountConfig(session: SessionInfo, installations: InstallationAccount[] | null = null): object {
  return {
    hosted: true,
    account: {
      state: session.state, login: session.login, user_id: session.userId, anthropic_key: session.hasAnthropicKey,
      ...(session.state === "signed_out" ? { reason: session.reason } : {}),
    },
    ...(session.state === "signed_in" && installations ? { installations } : {}),
  };
}
