/**
 * Hosted mode (docs/api.md, "Hosted sign-in"; docs/plans/github-app.md): one Worker serves everyone through the PRHub
 * GitHub App. A person signs in with GitHub, and every read and write for them goes with their own user access token.
 * Off unless `HOSTED` is `on`; a self-hosted Worker never reaches anything here.
 */
import type { AccountCore, SessionInfo, SignedOutReason, TokenAnswer } from "./account-core.ts";
import { userIdOf } from "./account-core.ts";
import { bodyOf, parseFinishInput, parseSender } from "./boundary.ts";
import { type Env, isSet } from "./env.ts";
import { authorizeUrl, exchangeCode, type Fetch, type OAuthApp, readUser } from "./oauth.ts";
import { deviceSecretOf, fingerprintOf } from "./pairing.ts";
import {
  isPkceChallenge, type Keyring, parseKeyring, pkceChallengeOf, randomToken,
} from "./token-crypto.ts";
import { verifySignature } from "./webhook.ts";

/** A sign-in has this long between `/auth/github/start` and GitHub's callback. */
export const SIGN_IN_MS = 10 * 60_000;

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

/**
 * The Worker as it acts for one signed-in person: their token and login, their objects (`user:<id>`), their R2 prefix.
 * The features that would spend Jai's Anthropic key, or serve only Jai, stay off until 6c and 6e decide them.
 */
export function userEnv(env: Env, user: { userId: string; login: string; token: string }): Env {
  return {
    ...env,
    GITHUB_TOKEN: user.token,
    GITHUB_LOGIN: user.login,
    SIGNED_IN_USER_ID: user.userId,
    GITHUB_ORGS: undefined,
    APP_TOKEN: undefined,
    HUB_TOKEN: undefined,
    WEBHOOK_SECRET: undefined,
    ANTHROPIC_API_KEY: undefined,
    ASK_ANTHROPIC_API_KEY: undefined,
    ASK_AGENT_ID: undefined,
    FEEDBACK_AGENT_ID: undefined,
    AGENT_PAGER_URL: undefined,
    LINEAR_API_KEY: undefined,
  };
}

/** What the routes reach: the Durable Objects, R2 and GitHub, so a test can stand in for each. */
export interface HostedServices {
  account(userId: string): AccountApi;
  signIns: {
    begin(id: string, pending: PendingSignIn): Promise<void>;
    take(id: string): Promise<PendingSignIn | null>;
  };
  index(userId: string): UserIndexApi;
  /** Deletes the person's R2 objects (`users/<id>/`). */
  deleteStored(userId: string): Promise<void>;
  fetch: Fetch;
  now(): number;
}

export type AccountApi = Pick<AccountCore,
  "signIn" | "finish" | "session" | "accessToken" | "tokenAfterUnauthorized" | "signOutEverywhere" | "signOut"
  | "deleteAccount">;

/** The part of a person's `PrIndex` sign-in touches. */
export interface UserIndexApi {
  bindUser(userId: number): unknown;
  tick(now: number): unknown;
  signedOut(reason: SignedOutReason): unknown;
  forgetDevices(): unknown;
  deleteEverything(): unknown;
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
    deleteStored: (userId) => deletePrefix(env.DIFFS, `users/${userId}/`),
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
    expires_at: services.now() + SIGN_IN_MS,
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
): Promise<(SessionInfo & { fingerprint: string }) | null> {
  const secret = deviceSecretOf(request.headers.get("Authorization"));
  const userId = userIdOf(secret);
  if (!secret || !userId) {
    return null;
  }
  const fingerprint = await fingerprintOf(secret);
  const session = await services.account(userId).session(fingerprint);
  return session && { ...session, fingerprint };
}

/** `POST /auth/signout`: this phone's session ends. The last phone out takes the tokens and push registrations along. */
export async function signOutRoute(request: Request, services: HostedServices): Promise<Response> {
  const session = await sessionOf(request, services);
  if (!session) {
    return errorAnswer(401, "unauthorized", "send the session secret as the bearer");
  }
  if (await services.account(session.userId).signOut(session.fingerprint)) {
    await services.index(session.userId).forgetDevices();
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
  const { revoked } = await services.account(session.userId).deleteAccount();
  await services.index(session.userId).deleteEverything();
  await services.deleteStored(session.userId);
  return Response.json({ deleted: true, github_revoked: revoked }, { headers: { "Cache-Control": "no-store" } });
}

/**
 * `POST /github/webhook` on the hosted Worker. `github_app_authorization` `revoked` signs the person out everywhere.
 * Pull request events are taken and dropped until 6c routes them per installation; the poll covers them meanwhile.
 */
export async function hostedWebhook(request: Request, env: Env, services: HostedServices): Promise<Response> {
  if (!isSet(env.WEBHOOK_SECRET)) {
    return new Response("not found\n", { status: 404 });
  }
  const body = await request.arrayBuffer();
  if (!(await verifySignature(body, request.headers.get("X-Hub-Signature-256"), env.WEBHOOK_SECRET))) {
    return new Response("unauthenticated\n", { status: 401 });
  }
  if (request.headers.get("X-GitHub-Event") === "github_app_authorization") {
    let payload: unknown = null;
    try {
      payload = JSON.parse(new TextDecoder().decode(body));
    } catch {
      // Not JSON: nothing to act on.
    }
    const delivery = parseSender(payload);
    if (delivery?.action === "revoked") {
      await services.account(String(delivery.sender.id)).signOutEverywhere("revoked");
    }
  }
  return new Response(null, { status: 202 });
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
    return hostedWebhook(request, env, services);
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

/** What `GET /device/config` adds on the hosted Worker. */
export function hostedAccountConfig(session: SessionInfo): object {
  return {
    hosted: true,
    account: {
      state: session.state, login: session.login, user_id: session.userId,
      ...(session.state === "signed_out" ? { reason: session.reason } : {}),
    },
  };
}
