import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { NO_AI, REFRESH_MARGIN_MS, userIdOf } from "../src/account-core.ts";
import { deviceConfig } from "../src/config.ts";
import { scopedKey } from "../src/env.ts";
import { authenticate, hostedAccountConfig, hostedMode, userEnv } from "../src/hosted.ts";
import {
  base64UrlOf, openToken, parseKeyring, pkceChallengeOf, randomToken, sealToken,
} from "../src/token-crypto.ts";
import {
  APP, APP_STATE, APP_VERIFIER, bearer, callback, env, HOUR, hostedWorld, KEY, keyOf, ORIGIN, signIn, startSignIn,
} from "./hosted-world.ts";

// --- Encryption -----------------------------------------------------------------------------------------------------

test("a sealed token opens with the same key and associated data, and its bytes are not the token's", async () => {
  const keyring = await parseKeyring(KEY);
  assert.ok(keyring);
  const sealed = await sealToken(keyring, "ghu_secret", "prhub:user:1:access");
  assert.match(sealed, /^v1\.k1\.[\w-]{16}\.[\w-]+$/);
  assert.equal(sealed.includes("ghu_secret"), false);
  assert.deepEqual(await openToken(keyring, sealed, "prhub:user:1:access"), { plaintext: "ghu_secret", isStale: false });
  assert.notEqual(await sealToken(keyring, "ghu_secret", "prhub:user:1:access"), sealed, "a new IV every time");
});

test("a changed byte, another person's or field's data, or an unknown key opens nothing", async () => {
  const keyring = await parseKeyring(KEY);
  assert.ok(keyring);
  const sealed = await sealToken(keyring, "ghu_secret", "prhub:user:1:access");
  const [version, id, iv, body] = sealed.split(".");
  const bytes = Buffer.from(body, "base64url");
  bytes[0] ^= 1;
  const tampered = [version, id, iv, base64UrlOf(new Uint8Array(bytes))].join(".");
  assert.equal(await openToken(keyring, tampered, "prhub:user:1:access"), null);
  assert.equal(await openToken(keyring, sealed, "prhub:user:2:access"), null, "another person");
  assert.equal(await openToken(keyring, sealed, "prhub:user:1:refresh"), null, "another field");
  const other = await parseKeyring(`k2:${keyOf(2)}`);
  assert.ok(other);
  assert.equal(await openToken(other, sealed, "prhub:user:1:access"), null, "a key it was not sealed with");
  assert.equal(await openToken(keyring, "v2.k1.x.y", "prhub:user:1:access"), null);
  assert.equal(await openToken(keyring, `${sealed}.extra`, "prhub:user:1:access"), null);
});

test("a rotated keyring seals with its first key and still opens what an older key sealed", async () => {
  const old = await parseKeyring(KEY);
  const rotated = await parseKeyring(`k2:${keyOf(2)}, ${KEY}`);
  assert.ok(old && rotated);
  const sealed = await sealToken(old, "ghu_secret", "a");
  assert.deepEqual(await openToken(rotated, sealed, "a"), { plaintext: "ghu_secret", isStale: true });
  assert.match(await sealToken(rotated, "ghu_secret", "a"), /^v1\.k2\./);
});

test("a keyring entry must be an id and 32 bytes, with no id twice", async () => {
  assert.equal(await parseKeyring(undefined), null);
  assert.equal(await parseKeyring(keyOf(1)), null, "no id");
  assert.equal(await parseKeyring(`k1:${Buffer.alloc(16).toString("base64")}`), null, "16 bytes");
  assert.equal(await parseKeyring(`k1:${keyOf(1)},k1:${keyOf(2)}`), null, "the same id twice");
  assert.equal(await parseKeyring("bad id:xyz"), null);
});

test("PKCE S256 is base64url of the verifier's SHA-256, unpadded", async () => {
  const verifier = randomToken();
  assert.equal(await pkceChallengeOf(verifier), createHash("sha256").update(verifier).digest("base64url"));
  assert.equal(randomToken().length, 43);
});

// --- Sign-in --------------------------------------------------------------------------------------------------------

test("start keeps the app's state and challenge and sends GitHub a challenge of the Worker's own", async () => {
  const world = hostedWorld();
  const authorize = await startSignIn(world);
  assert.equal(authorize.origin + authorize.pathname, "https://github.com/login/oauth/authorize");
  assert.equal(authorize.searchParams.get("client_id"), APP.clientId);
  assert.equal(authorize.searchParams.get("redirect_uri"), `${ORIGIN}/auth/github/callback`);
  assert.equal(authorize.searchParams.get("code_challenge_method"), "S256");
  const id = authorize.searchParams.get("state") ?? "";
  const kept = world.pending.get(id);
  assert.ok(kept, "the Worker's state names the sign-in it keeps");
  assert.equal(kept.app_state, APP_STATE);
  assert.equal(kept.app_challenge, await pkceChallengeOf(APP_VERIFIER));
  assert.notEqual(authorize.searchParams.get("code_challenge"), kept.app_challenge, "the app's verifier is not GitHub's");
  assert.equal(await pkceChallengeOf(kept.github_verifier), authorize.searchParams.get("code_challenge"));
  assert.equal(id === APP_STATE, false);
});

test("start refuses a missing or plain challenge and a short state", async () => {
  const world = hostedWorld();
  const challenge = await pkceChallengeOf(APP_VERIFIER);
  for (const params of [
    { state: APP_STATE, code_challenge: challenge },
    { state: APP_STATE, code_challenge: APP_VERIFIER, code_challenge_method: "plain" },
    { state: "short", code_challenge: challenge, code_challenge_method: "S256" },
    { state: APP_STATE, code_challenge_method: "S256" },
  ]) {
    const answer = await world.route(`/auth/github/start?${new URLSearchParams(params)}`);
    assert.equal(answer.status, 400, JSON.stringify(params));
  }
  assert.equal(world.pending.size, 0);
});

test("the callback trades the code with the Worker's verifier and hands the app a one-time code", async () => {
  const world = hostedWorld();
  const authorize = await startSignIn(world);
  const done = await callback(world, { code: "gh-code", state: authorize.searchParams.get("state") ?? "" });
  assert.equal(done.origin + done.pathname, `${ORIGIN}/auth/github/done`);
  assert.equal(done.searchParams.get("state"), APP_STATE);
  assert.equal(userIdOf(done.searchParams.get("code")), "4242");
  const exchange = world.github.calls.find((call) => call.url.endsWith("/access_token"));
  assert.equal(exchange?.form?.get("client_secret"), APP.clientSecret);
  assert.equal(exchange?.form?.get("redirect_uri"), `${ORIGIN}/auth/github/callback`);
  await Promise.all(world.waited);
  assert.deepEqual(world.indexes.get("4242")?.calls, ["bind:4242", "tick"]);
  const stored = JSON.stringify([...world.stores.get("4242")?.map.values() ?? []]);
  assert.equal(stored.includes("ghu_1") || stored.includes("ghr_1"), false, "no token in the clear at rest");
});

test("finish swaps the code and the app's verifier for a session, once", async () => {
  const world = hostedWorld();
  const authorize = await startSignIn(world);
  const done = await callback(world, { code: "gh-code", state: authorize.searchParams.get("state") ?? "" });
  const code = done.searchParams.get("code");
  const wrong = await world.route("/auth/github/finish", {
    method: "POST", body: JSON.stringify({ code, code_verifier: "w".repeat(43) }),
  });
  assert.equal(wrong.status, 401);
  assert.equal((await wrong.json() as { error: { code: string } }).error.code, "sign_in_invalid");
  const late = await world.route("/auth/github/finish", {
    method: "POST", body: JSON.stringify({ code, code_verifier: APP_VERIFIER }),
  });
  assert.equal(late.status, 401, "a wrong verifier burns the code");
  const bad = await world.route("/auth/github/finish", { method: "POST", body: "not json" });
  assert.equal(bad.status, 400);

  const secret = await signIn(world);
  assert.equal(userIdOf(secret), "4242");
  const auth = await authenticate(new Request(`${ORIGIN}/prs`, bearer(secret)), world.workerEnv, world.services);
  assert.ok("env" in auth);
  assert.equal(auth.env.GITHUB_TOKEN, "ghu_2");
  assert.equal(auth.env.GITHUB_LOGIN, "octocat");
  assert.equal(auth.env.SIGNED_IN_USER_ID, "4242");
});

test("a one-time code expires after five minutes", async () => {
  const world = hostedWorld();
  const authorize = await startSignIn(world);
  const done = await callback(world, { code: "gh-code", state: authorize.searchParams.get("state") ?? "" });
  world.clock.now += 5 * 60_000 + 1;
  const late = await world.route("/auth/github/finish", {
    method: "POST", body: JSON.stringify({ code: done.searchParams.get("code"), code_verifier: APP_VERIFIER }),
  });
  assert.equal(late.status, 401);
});

test("callback errors go back to the app by name, with its state when the Worker knows it", async () => {
  const world = hostedWorld();
  const installed = await world.route("/auth/github/callback?code=x&installation_id=1&setup_action=install");
  assert.equal(installed.status, 200, "an install on github.com gets a page, and its code is not traded");
  assert.match(await installed.text(), /Open PRHub/);

  assert.equal((await callback(world, { code: "gh-code", state: randomToken() })).searchParams.get("error"),
    "sign_in_expired");
  assert.equal((await callback(world, { code: "gh-code", state: "<script>" })).searchParams.get("error"),
    "sign_in_expired");

  const denied = await startSignIn(world);
  const deniedDone = await callback(world, { error: "access_denied", state: denied.searchParams.get("state") ?? "" });
  assert.equal(deniedDone.searchParams.get("error"), "access_denied");
  assert.equal(deniedDone.searchParams.get("state"), APP_STATE);

  const used = await startSignIn(world);
  const id = used.searchParams.get("state") ?? "";
  await callback(world, { code: "gh-code", state: id });
  assert.equal((await callback(world, { code: "gh-code", state: id })).searchParams.get("error"), "sign_in_expired",
    "a sign-in is taken once");

  const stale = await startSignIn(world);
  world.clock.now += 10 * 60_000 + 1;
  assert.equal((await callback(world, { code: "gh-code", state: stale.searchParams.get("state") ?? "" }))
    .searchParams.get("error"), "sign_in_expired");

  const refused = await startSignIn(world);
  world.github.challenge = "someone else's";
  assert.equal((await callback(world, { code: "gh-code", state: refused.searchParams.get("state") ?? "" }))
    .searchParams.get("error"), "github_refused", "GitHub refuses a verifier that does not match");
});

// --- Tokens ---------------------------------------------------------------------------------------------------------

test("a token near its 8 hours is refreshed first, once for every request at the same time", async () => {
  const world = hostedWorld();
  await signIn(world);
  const account = world.services.account("4242");
  assert.deepEqual(await account.accessToken(), { kind: "ok", token: "ghu_1", login: "octocat", userId: "4242", ai: NO_AI });
  assert.equal(world.github.refreshCalls(), 0);
  world.clock.now += 8 * HOUR - REFRESH_MARGIN_MS + 1;
  const answers = await Promise.all([account.accessToken(), account.accessToken(), account.accessToken()]);
  assert.equal(world.github.refreshCalls(), 1, "two refreshes at once would sign the person out");
  assert.ok(answers.every((answer) => answer.kind === "ok" && answer.token === "ghu_2"));
  assert.equal(world.github.calls.at(-1)?.form?.get("refresh_token"), "ghr_1");
  assert.deepEqual(await account.accessToken(), { kind: "ok", token: "ghu_2", login: "octocat", userId: "4242", ai: NO_AI });
});

test("a 401 refreshes once; a token another request already replaced is just handed over", async () => {
  const world = hostedWorld();
  await signIn(world);
  const account = world.services.account("4242");
  assert.equal((await account.tokenAfterUnauthorized("ghu_1")).kind, "ok");
  assert.equal(world.github.refreshCalls(), 1);
  const again = await account.tokenAfterUnauthorized("ghu_1");
  assert.deepEqual(again, { kind: "ok", token: "ghu_2", login: "octocat", userId: "4242", ai: NO_AI });
  assert.equal(world.github.refreshCalls(), 1);
});

test("a refused refresh signs the person out everywhere and asks the phones to sign in again", async () => {
  const world = hostedWorld();
  const secret = await signIn(world);
  world.github.liveRefresh = "revoked on GitHub";
  world.clock.now += 8 * HOUR;
  assert.deepEqual(await world.services.account("4242").accessToken(), { kind: "signed_out" });
  assert.deepEqual(world.signedOut, ["revoked"]);
  assert.ok(world.indexes.get("4242")?.calls.includes("signed_out:revoked"));
  const auth = await authenticate(new Request(`${ORIGIN}/prs`, bearer(secret)), world.workerEnv, world.services);
  assert.ok("answer" in auth);
  assert.equal(auth.answer.status, 401);
  assert.equal((await auth.answer.json() as { error: { code: string } }).error.code, "signed_out");
  assert.ok(auth.session);
  assert.deepEqual(hostedAccountConfig(auth.session), {
    hosted: true,
    account: { state: "signed_out", login: "octocat", user_id: "4242", anthropic_key: false, reason: "revoked" },
  });
  assert.equal(JSON.stringify([...world.stores.get("4242")?.map.values() ?? []]).includes("v1.k1"), false,
    "the sealed tokens are gone");
});

test("GitHub down keeps the person signed in and the token while it lives", async () => {
  const world = hostedWorld();
  await signIn(world);
  world.github.refusal = "temporarily_unavailable";
  world.clock.now += 8 * HOUR - REFRESH_MARGIN_MS + 1;
  assert.equal((await world.services.account("4242").accessToken()).kind, "ok");
  world.clock.now += REFRESH_MARGIN_MS;
  assert.equal((await world.services.account("4242").tokenAfterUnauthorized("ghu_1")).kind, "unavailable");
  assert.deepEqual(world.signedOut, []);
});

test("a refresh token past its six months signs the person out without asking GitHub", async () => {
  const world = hostedWorld();
  await signIn(world);
  world.clock.now += 15_897_600_000;
  assert.deepEqual(await world.services.account("4242").accessToken(), { kind: "signed_out" });
  assert.deepEqual(world.signedOut, ["refresh_expired"]);
  assert.equal(world.github.refreshCalls(), 0);
});

test("the github_app_authorization revoked event signs the person out, signed with the webhook secret only", async () => {
  const world = hostedWorld();
  await signIn(world);
  const body = JSON.stringify({ action: "revoked", sender: { id: 4242, login: "octocat" } });
  const sign = async (secret: string) => {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" },
      false, ["sign"]);
    return `sha256=${Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))).toString("hex")}`;
  };
  const deliver = async (secret: string) => world.route("/github/webhook", {
    method: "POST", body,
    headers: { "X-GitHub-Event": "github_app_authorization", "X-Hub-Signature-256": await sign(secret) },
  });
  assert.equal((await deliver("not the secret")).status, 401);
  assert.deepEqual(world.signedOut, []);
  assert.equal((await deliver("hook-secret")).status, 202);
  assert.deepEqual(world.signedOut, ["revoked"]);
});

// --- Sign out and Delete Account ------------------------------------------------------------------------------------

test("signing out ends this phone's session; the last one out takes the tokens and push registrations", async () => {
  const world = hostedWorld();
  const first = await signIn(world);
  const second = await signIn(world);
  assert.equal((await world.route("/auth/signout", { method: "POST", ...bearer(first) })).status, 204);
  assert.equal((await authenticate(new Request(`${ORIGIN}/prs`, bearer(first)), world.workerEnv, world.services) as
    { answer: Response }).answer.status, 401);
  assert.ok("env" in await authenticate(new Request(`${ORIGIN}/prs`, bearer(second)), world.workerEnv, world.services));
  assert.equal(world.indexes.get("4242")?.calls.includes("forget_devices"), false);
  const fingerprint = (secret: string) => createHash("sha256").update(secret).digest("hex");
  assert.ok(world.indexes.get("4242")?.calls.includes(`forget_push:${fingerprint(first)}`));
  assert.deepEqual(await world.accounts.get("4242")?.liveSessionFingerprints(), [fingerprint(second)]);
  assert.equal((await world.route("/auth/signout", { method: "POST", ...bearer(second) })).status, 204);
  assert.ok(world.indexes.get("4242")?.calls.includes("forget_devices"));
  assert.deepEqual(await world.services.account("4242").accessToken(), { kind: "signed_out" });
  assert.equal((await world.route("/auth/signout", { method: "POST" })).status, 401);
});

test("Delete Account revokes the grant on GitHub and deletes the account, index and stored PRs", async () => {
  const world = hostedWorld();
  const secret = await signIn(world);
  const answer = await world.route("/account", { method: "DELETE", ...bearer(secret) });
  assert.equal(answer.status, 200);
  assert.deepEqual(await answer.json(), { deleted: true, github_revoked: true });
  const revoke = world.github.calls.find((call) => call.method === "DELETE");
  assert.equal(revoke?.url, `https://api.github.com/applications/${APP.clientId}/grant`);
  assert.equal(revoke?.headers.get("Authorization"), `Basic ${btoa(`${APP.clientId}:${APP.clientSecret}`)}`);
  assert.equal(world.stores.get("4242")?.map.size, 0);
  assert.ok(world.indexes.get("4242")?.calls.includes("delete"));
  assert.deepEqual(world.deleted, ["4242"]);
  assert.equal((await world.route("/account", { method: "DELETE", ...bearer(secret) })).status, 401);
});

test("a bearer that is no session is refused, whatever its shape", async () => {
  const world = hostedWorld();
  await signIn(world);
  for (const header of [undefined, "Bearer 4242.short", `Bearer 4242.${randomToken()}`, `Bearer 1.${randomToken()}`]) {
    const auth = await authenticate(new Request(`${ORIGIN}/prs`, header ? { headers: { Authorization: header } } : {}),
      world.workerEnv, world.services);
    assert.ok("answer" in auth);
    assert.equal(auth.answer.status, 401);
  }
});

// --- Hosted and self-hosted -----------------------------------------------------------------------------------------

test("hosted mode is off unless HOSTED is on, and serves nothing when it is on but incomplete", () => {
  assert.deepEqual(hostedMode(env({ GITHUB_TOKEN: "t" })), { kind: "off" });
  assert.deepEqual(hostedMode(env({ GITHUB_TOKEN: "t", GITHUB_APP_CLIENT_ID: "x", HOSTED: "" })), { kind: "off" });
  assert.deepEqual(hostedMode(env({ HOSTED: "on", GITHUB_APP_CLIENT_ID: "x" })), {
    kind: "misconfigured",
    missing: ["GITHUB_APP_CLIENT_SECRET", "TOKEN_ENCRYPTION_KEY", "USER_ACCOUNTS", "SIGN_INS", "INSTALLATIONS", "IP_LIMITS"],
  });
  assert.equal(hostedMode(hostedWorld().workerEnv).kind, "on");
});

test("a person's env acts with their token, under their own objects and R2 prefix, with AI off", () => {
  const base = env({
    GITHUB_TOKEN: "unused", ANTHROPIC_API_KEY: "sk-test", ASK_AGENT_ID: "a", ASK_ENVIRONMENT_ID: "e", ASK_VAULT_ID: "v",
    ASK_CREDENTIAL_ID: "c", ASK_ANTHROPIC_API_KEY: "k", WEBHOOK_SECRET: "w", APP_TOKEN: "jai",
  });
  const person = userEnv(base, { userId: "4242", login: "octocat", token: "ghu_x" });
  assert.equal(person.GITHUB_TOKEN, "ghu_x");
  assert.equal(person.APP_TOKEN, undefined);
  assert.equal(scopedKey(person, "o/r/1/abc.diff"), "users/4242/o/r/1/abc.diff");
  assert.equal(scopedKey(base, "o/r/1/abc.diff"), "o/r/1/abc.diff", "a self-hosted Worker's keys are as they were");
  assert.deepEqual(deviceConfig(person, "octocat").features,
    { ask_ai: false, key_lines: false, rewrite: false, feedback: false, finder: false, push: false, webhooks: false });
});

test("only a login in SUBSCRIPTION_LOGINS runs AI on the Worker's subscription", () => {
  const base = env({ CLAUDE_CODE_OAUTH_TOKEN: "oat-test", SUBSCRIPTION_LOGINS: " OctoCat ,hubot",
    AGENT: {} as Env["AGENT"] });
  const listed = userEnv(base, { userId: "4242", login: "octocat", token: "ghu_x" });
  assert.equal(listed.CLAUDE_CODE_OAUTH_TOKEN, "oat-test");
  assert.equal(deviceConfig(listed, "octocat").features.key_lines, true);
  const other = userEnv(base, { userId: "5151", login: "mona", token: "ghu_y" });
  assert.equal(other.CLAUDE_CODE_OAUTH_TOKEN, undefined);
  assert.equal(deviceConfig(other, "mona").features.key_lines, false);
});

test("the association file names the app that may catch the callback", async () => {
  const world = hostedWorld();
  assert.deepEqual(await (await world.route("/.well-known/apple-app-site-association")).json(),
    { webcredentials: { apps: ["TEAMID.com.example.prhub"] } });
  assert.equal((await world.route("/device/pair", { method: "POST" })).status, 404, "no pairing on the hosted Worker");
});
