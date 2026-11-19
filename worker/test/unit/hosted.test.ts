// The hosted Worker's routes (`hosted.ts`) over the in-memory hosted world: sign-in, sign-out and Delete Account, the
// session bearer, the webhook's revoke, `/device/config`'s installations, the person's own Anthropic key, and the per-IP
// sign-in limits.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test, vi } from "vitest";
import { userIdOf } from "../../src/account-core.ts";
import { deviceConfig } from "../../src/config.ts";
import {
  authenticate,
  canSeeWith,
  configInstallations,
  hostedAccountConfig,
} from "../../src/hosted.ts";
import { parseRepoFullName, type RepoFullName } from "../../src/ids.ts";
import { gitHubReserveOf, parseLimits, WorkerMode } from "../../src/limits.ts";
import { pkceChallengeOf, randomToken } from "../../src/token-crypto.ts";
import {
  ALICE,
  APP,
  APP_STATE,
  APP_VERIFIER,
  ASK_RESOURCES,
  bearer,
  callback,
  deliver,
  type FakeUser,
  hostedWorld,
  ORIGIN,
  signIn,
  startSignIn,
  twoOrgs,
  type World,
} from "../support/hosted-world.ts";

const MINUTE = 60_000;
const RESERVE = gitHubReserveOf(parseLimits({}, WorkerMode.Hosted));
const repo = (name: string) => parseRepoFullName(name) as RepoFullName;

// --- Sign-in ------------------------------------------------------------------------------------------------------

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
  assert.notEqual(
    authorize.searchParams.get("code_challenge"),
    kept.app_challenge,
    "the app's verifier is not GitHub's",
  );
  assert.equal(
    await pkceChallengeOf(kept.github_verifier),
    authorize.searchParams.get("code_challenge"),
  );
  assert.equal(id === APP_STATE, false);
});

test("start refuses a missing or plain challenge and a short state", async () => {
  const world = hostedWorld();
  const challenge = await pkceChallengeOf(APP_VERIFIER);
  const invalidParameters: Record<string, string>[] = [
    { state: APP_STATE, code_challenge: challenge },
    { state: APP_STATE, code_challenge: APP_VERIFIER, code_challenge_method: "plain" },
    { state: "short", code_challenge: challenge, code_challenge_method: "S256" },
    { state: APP_STATE, code_challenge_method: "S256" },
  ];
  for (const params of invalidParameters) {
    const answer = await world.route(`/auth/github/start?${new URLSearchParams(params)}`);
    assert.equal(answer.status, 400, JSON.stringify(params));
  }
  assert.equal(world.pending.size, 0);
});

test("the callback trades the code with the Worker's verifier and hands the app a one-time code", async () => {
  const world = hostedWorld();
  const authorize = await startSignIn(world);
  const done = await callback(world, {
    code: "gh-code",
    state: authorize.searchParams.get("state") ?? "",
  });
  assert.equal(done.origin + done.pathname, `${ORIGIN}/auth/github/done`);
  assert.equal(done.searchParams.get("state"), APP_STATE);
  assert.equal(userIdOf(done.searchParams.get("code")), "4242");
  const exchange = world.github.calls.find((call) => call.url.endsWith("/access_token"));
  assert.equal(exchange?.form?.get("client_secret"), APP.clientSecret);
  assert.equal(exchange?.form?.get("redirect_uri"), `${ORIGIN}/auth/github/callback`);
  await Promise.all(world.waited);
  assert.deepEqual(world.indexes.get("4242")?.calls, ["bind:4242", "tick"]);
  const stored = JSON.stringify([...(world.stores.get("4242")?.map.values() ?? [])]);
  assert.equal(
    stored.includes("ghu_1") || stored.includes("ghr_1"),
    false,
    "no token in the clear at rest",
  );
});

test("finish swaps the code and the app's verifier for a session, once", async () => {
  const world = hostedWorld();
  const authorize = await startSignIn(world);
  const done = await callback(world, {
    code: "gh-code",
    state: authorize.searchParams.get("state") ?? "",
  });
  const code = done.searchParams.get("code");
  const wrong = await world.route("/auth/github/finish", {
    method: "POST",
    body: JSON.stringify({ code, code_verifier: "w".repeat(43) }),
  });
  assert.equal(wrong.status, 401);
  assert.equal(((await wrong.json()) as { error: { code: string } }).error.code, "sign_in_invalid");
  const late = await world.route("/auth/github/finish", {
    method: "POST",
    body: JSON.stringify({ code, code_verifier: APP_VERIFIER }),
  });
  assert.equal(late.status, 401, "a wrong verifier burns the code");
  const bad = await world.route("/auth/github/finish", { method: "POST", body: "not json" });
  assert.equal(bad.status, 400);

  const secret = await signIn(world);
  assert.equal(userIdOf(secret), "4242");
  const auth = await authenticate(
    new Request(`${ORIGIN}/prs`, bearer(secret)),
    world.workerEnv,
    world.services,
  );
  assert.ok("env" in auth);
  assert.equal(auth.env.GITHUB_TOKEN, "ghu_2");
  assert.equal(auth.env.GITHUB_LOGIN, "octocat");
  assert.equal(auth.env.SIGNED_IN_USER_ID, "4242");
});

test("a one-time code expires after five minutes", async () => {
  const world = hostedWorld();
  const authorize = await startSignIn(world);
  const done = await callback(world, {
    code: "gh-code",
    state: authorize.searchParams.get("state") ?? "",
  });
  world.clock.now += 5 * 60_000 + 1;
  const late = await world.route("/auth/github/finish", {
    method: "POST",
    body: JSON.stringify({ code: done.searchParams.get("code"), code_verifier: APP_VERIFIER }),
  });
  assert.equal(late.status, 401);
});

test("callback errors go back to the app by name, with its state when the Worker knows it", async () => {
  const world = hostedWorld();
  const installed = await world.route(
    "/auth/github/callback?code=x&installation_id=1&setup_action=install",
  );
  assert.equal(
    installed.status,
    200,
    "an install on github.com gets a page, and its code is not traded",
  );
  assert.match(await installed.text(), /Open PRHub/);

  assert.equal(
    (await callback(world, { code: "gh-code", state: randomToken() })).searchParams.get("error"),
    "sign_in_expired",
  );
  assert.equal(
    (await callback(world, { code: "gh-code", state: "<script>" })).searchParams.get("error"),
    "sign_in_expired",
  );

  const denied = await startSignIn(world);
  const deniedDone = await callback(world, {
    error: "access_denied",
    state: denied.searchParams.get("state") ?? "",
  });
  assert.equal(deniedDone.searchParams.get("error"), "access_denied");
  assert.equal(deniedDone.searchParams.get("state"), APP_STATE);

  const used = await startSignIn(world);
  const id = used.searchParams.get("state") ?? "";
  await callback(world, { code: "gh-code", state: id });
  assert.equal(
    (await callback(world, { code: "gh-code", state: id })).searchParams.get("error"),
    "sign_in_expired",
    "a sign-in is taken once",
  );

  const stale = await startSignIn(world);
  world.clock.now += 10 * 60_000 + 1;
  assert.equal(
    (
      await callback(world, { code: "gh-code", state: stale.searchParams.get("state") ?? "" })
    ).searchParams.get("error"),
    "sign_in_expired",
  );

  const refused = await startSignIn(world);
  world.github.challenge = "someone else's";
  assert.equal(
    (
      await callback(world, { code: "gh-code", state: refused.searchParams.get("state") ?? "" })
    ).searchParams.get("error"),
    "github_refused",
    "GitHub refuses a verifier that does not match",
  );
});

test("the pending sign-in and the one-time code live as long as their limits say", async () => {
  const world = hostedWorld({ LIMIT_SIGN_IN_CODE_MINUTES: "1", LIMIT_SIGN_IN_MINUTES: "2" });
  const authorize = await startSignIn(world);
  const [pending] = world.pending.values();
  assert.equal(pending.expires_at, world.clock.now + 2 * MINUTE);
  const done = await callback(world, {
    code: "gh-code",
    state: authorize.searchParams.get("state") ?? "",
  });
  world.clock.now += MINUTE + 1;
  const finish = await world.route("/auth/github/finish", {
    method: "POST",
    body: JSON.stringify({ code: done.searchParams.get("code"), code_verifier: APP_VERIFIER }),
  });
  assert.equal(finish.status, 401, "the code outlived sign_in_code_minutes");
});

test("the github_app_authorization revoked event signs the person out, signed with the webhook secret only", async () => {
  const world = hostedWorld();
  await signIn(world);
  const body = JSON.stringify({ action: "revoked", sender: { id: 4242, login: "octocat" } });
  const sign = async (secret: string) => {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    return `sha256=${Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))).toString("hex")}`;
  };
  const deliver = async (secret: string) =>
    world.route("/github/webhook", {
      method: "POST",
      body,
      headers: {
        "X-GitHub-Event": "github_app_authorization",
        "X-Hub-Signature-256": await sign(secret),
      },
    });
  assert.equal((await deliver("not the secret")).status, 401);
  assert.deepEqual(world.signedOut, []);
  assert.equal((await deliver("hook-secret")).status, 202);
  assert.deepEqual(world.signedOut, ["revoked"]);
});

// --- Sign out and Delete Account ----------------------------------------------------------------------------------

test("signing out ends this phone's session; the last one out takes the tokens and push registrations", async () => {
  const world = hostedWorld();
  const first = await signIn(world);
  const second = await signIn(world);
  assert.equal(
    (await world.route("/auth/signout", { method: "POST", ...bearer(first) })).status,
    204,
  );
  assert.equal(
    (
      (await authenticate(
        new Request(`${ORIGIN}/prs`, bearer(first)),
        world.workerEnv,
        world.services,
      )) as { answer: Response }
    ).answer.status,
    401,
  );
  assert.ok(
    "env" in
      (await authenticate(
        new Request(`${ORIGIN}/prs`, bearer(second)),
        world.workerEnv,
        world.services,
      )),
  );
  assert.equal(world.indexes.get("4242")?.calls.includes("forget_devices"), false);
  const fingerprint = (secret: string) => createHash("sha256").update(secret).digest("hex");
  assert.ok(world.indexes.get("4242")?.calls.includes(`forget_push:${fingerprint(first)}`));
  assert.deepEqual(await world.accounts.get("4242")?.liveSessionFingerprints(), [
    fingerprint(second),
  ]);
  assert.equal(
    (await world.route("/auth/signout", { method: "POST", ...bearer(second) })).status,
    204,
  );
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
  assert.equal(
    revoke?.headers.get("Authorization"),
    `Basic ${btoa(`${APP.clientId}:${APP.clientSecret}`)}`,
  );
  assert.equal(world.stores.get("4242")?.map.size, 0);
  assert.ok(world.indexes.get("4242")?.calls.includes("delete"));
  assert.deepEqual(world.deleted, ["4242"]);
  assert.equal(
    (await world.route("/account", { method: "DELETE", ...bearer(secret) })).status,
    401,
  );
});

test("a bearer that is no session is refused, whatever its shape", async () => {
  const world = hostedWorld();
  await signIn(world);
  for (const header of [
    undefined,
    "Bearer 4242.short",
    `Bearer 4242.${randomToken()}`,
    `Bearer 1.${randomToken()}`,
  ]) {
    const auth = await authenticate(
      new Request(`${ORIGIN}/prs`, header ? { headers: { Authorization: header } } : {}),
      world.workerEnv,
      world.services,
    );
    assert.ok("answer" in auth);
    assert.equal(auth.answer.status, 401);
  }
});

// --- Hosted and self-hosted ---------------------------------------------------------------------------------------

test("the association file names the app that may catch the callback", async () => {
  const world = hostedWorld();
  assert.deepEqual(await (await world.route("/.well-known/apple-app-site-association")).json(), {
    webcredentials: { apps: ["TEAMID.com.example.prhub"] },
  });
  assert.equal(
    (await world.route("/device/pair", { method: "POST" })).status,
    404,
    "no pairing on the hosted Worker",
  );
});

// --- Who sees a repo ----------------------------------------------------------------------------------------------

test("the person's token decides in doubt: signed out is no, GitHub away or rate limited is ask again", async () => {
  const { world } = await twoOrgs();
  const account = world.services.account("1001");
  assert.equal(
    await canSeeWith(account, repo("acme/api"), world.github.fetch, world.clock.now, RESERVE),
    true,
  );
  assert.equal(
    await canSeeWith(account, repo("acme/secret"), world.github.fetch, world.clock.now, RESERVE),
    false,
  );
  world.github.headers = {
    "x-ratelimit-remaining": "0",
    "x-ratelimit-limit": "5000",
    "x-ratelimit-reset": "9999999999",
  };
  const limited = async () => new Response("{}", { status: 403, headers: world.github.headers });
  assert.equal(
    await canSeeWith(account, repo("acme/secret"), limited, world.clock.now, RESERVE),
    null,
  );
  const away = async () => new Response("", { status: 502 });
  assert.equal(
    await canSeeWith(account, repo("acme/secret"), away, world.clock.now, RESERVE),
    null,
  );
  await account.signOutEverywhere("revoked");
  assert.equal(
    await canSeeWith(account, repo("acme/api"), world.github.fetch, world.clock.now, RESERVE),
    false,
  );
});

// --- What the app shows of each installation ----------------------------------------------------------------------

/** What `GET /device/config` adds for the session: the account and the installations the last sync read. */
async function configOf(world: World, secret: string) {
  const auth = await authenticate(
    new Request(`${ORIGIN}/device/config`, bearer(secret)),
    world.workerEnv,
    world.services,
  );
  assert.ok("env" in auth);
  return hostedAccountConfig(
    auth.session,
    await world.services.account(auth.session.userId).installationAccounts(),
  ) as { installations?: { account: string; suspended: boolean }[] };
}

const accountsOf = async (world: World, secret: string) =>
  (await configOf(world, secret)).installations?.map((entry) => entry.account);

test("/device/config names each installation the person reaches, their own account first, as GitHub has it", async () => {
  const world = hostedWorld();
  world.github.installations.set(44, { account: "Zeta", repos: ["zeta/app"] });
  world.github.installations.set(11, {
    account: "acme",
    repos: ["acme/api", "acme/web", "acme/secret"],
    selection: "selected",
  });
  world.github.installations.set(55, { account: "alice", repos: ["alice/dotfiles"], type: "User" });
  world.github.installations.set(22, { account: "globex", repos: ["globex/web"] });
  world.github.grant(ALICE, ["zeta/app", "acme/api", "acme/web", "alice/dotfiles"]);
  const alice = await signIn(world, ALICE);
  assert.deepEqual(
    (await configOf(world, alice)).installations,
    [
      {
        account: "alice",
        account_type: "User",
        avatar_url: "https://avatars.githubusercontent.com/u/55?v=4",
        installation_id: 55,
        repository_selection: "all",
        suspended: false,
      },
      {
        account: "acme",
        account_type: "Organization",
        avatar_url: "https://avatars.githubusercontent.com/u/11?v=4",
        installation_id: 11,
        repository_selection: "selected",
        repo_count: 2,
        suspended: false,
      },
      {
        account: "Zeta",
        account_type: "Organization",
        avatar_url: "https://avatars.githubusercontent.com/u/44?v=4",
        installation_id: 44,
        repository_selection: "all",
        suspended: false,
      },
    ],
    "globex is not hers to see; repo_count is what her own token sees of a chosen few",
  );
});

test("installing on a new org shows in the installer's config at once; uninstalling takes it out", async () => {
  const world = hostedWorld();
  world.github.installations.set(11, { account: "acme", repos: ["acme/api"] });
  world.github.grant(ALICE, ["acme/api", "initech/shared"]);
  const alice = await signIn(world, ALICE);
  assert.deepEqual(await accountsOf(world, alice), ["acme"]);

  world.github.installations.set(33, { account: "initech", repos: ["initech/shared"] });
  await deliver(world, "installation", {
    action: "created",
    installation: { id: 33, account: { login: "initech" } },
    sender: { id: ALICE.id },
    repositories: [{ full_name: "initech/shared" }],
  });
  assert.deepEqual(
    await accountsOf(world, alice),
    ["acme", "initech"],
    "no wait for the next sync",
  );

  world.github.installations.delete(33);
  await deliver(world, "installation", {
    action: "deleted",
    installation: { id: 33, account: { login: "initech" } },
    sender: { id: ALICE.id },
  });
  assert.deepEqual(await accountsOf(world, alice), ["acme"]);
});

test("a suspended installation shows as suspended and keeps its members, so the sync still runs", async () => {
  const { world, alice } = await twoOrgs();
  const installation = world.github.installations.get(33);
  assert.ok(installation);
  installation.suspended = true;
  const reposReads = () =>
    world.github.calls.filter((call) => call.url.includes("/user/installations/33/repositories"))
      .length;
  const before = reposReads();
  await deliver(world, "installation", {
    action: "suspend",
    installation: { id: 33, account: { login: "initech" } },
    sender: { id: ALICE.id },
  });
  const listed = (await configOf(world, alice)).installations;
  assert.deepEqual(
    listed?.map(({ account, suspended }) => [account, suspended]),
    [
      ["acme", false],
      ["initech", true],
    ],
  );
  assert.deepEqual(
    [...((await world.installations.get("33")?.members()) ?? new Map()).keys()].sort(),
    ["1001", "2002"],
  );
  assert.equal(
    reposReads(),
    before,
    "GitHub lists no repos of a suspended installation, so none are asked for",
  );
});

test("a signed-out session's config, and one before the first sync, name no installations", async () => {
  const world = hostedWorld();
  world.github.installations.set(11, { account: "acme", repos: ["acme/api"] });
  world.github.grant(ALICE, ["acme/api"]);
  const alice = await signIn(world, ALICE);
  await world.stores.get("1001")?.delete(["installation_accounts"]);
  assert.equal("installations" in (await configOf(world, alice)), false);
  await world.services.account("1001").signOutEverywhere("revoked");
  const auth = await authenticate(
    new Request(`${ORIGIN}/device/config`, bearer(alice)),
    world.workerEnv,
    world.services,
  );
  assert.ok("answer" in auth && auth.session);
  assert.equal("installations" in hostedAccountConfig(auth.session, []), false);
});

/** `GET /device/config` as the route answers it (`configInstallations`), with `query` on its URL. */
async function liveConfigOf(world: World, secret: string, query = "") {
  const request = new Request(`${ORIGIN}/device/config${query}`, bearer(secret));
  const auth = await authenticate(request, world.workerEnv, world.services);
  assert.ok("env" in auth);
  const installations = await configInstallations(
    request,
    auth.session,
    world.services,
    (promise) => world.waited.push(promise),
  );
  await Promise.all(world.waited.splice(0));
  return (
    hostedAccountConfig(auth.session, installations) as { installations?: { account: string }[] }
  ).installations?.map((entry) => entry.account);
}

const installationReads = (world: World) =>
  world.github.calls.filter((call) =>
    call.url.startsWith("https://api.github.com/user/installations?"),
  ).length;

/** Signed in with the sign-in's own read of the installations still on its way, as the app's first config finds it. */
async function signedInBeforeTheFirstRead(world: World, user: FakeUser): Promise<string> {
  const secret = await signIn(world, user);
  const store = world.stores.get(String(user.id));
  await store?.put("installations", { ids: [], synced_at: world.clock.now - 1_000 });
  await store?.delete(["installation_accounts"]);
  return secret;
}

test("the first config after sign-in reads GitHub before it answers, so an App installed already shows at once", async () => {
  const world = hostedWorld();
  world.github.installations.set(11, { account: "acme", repos: ["acme/api"] });
  world.github.grant(ALICE, ["acme/api"]);
  const alice = await signedInBeforeTheFirstRead(world, ALICE);
  const before = installationReads(world);
  assert.deepEqual(
    await liveConfigOf(world, alice),
    ["acme"],
    "never the install hint for an App already installed",
  );
  assert.equal(installationReads(world), before + 1);
  assert.deepEqual(await liveConfigOf(world, alice), ["acme"]);
  assert.equal(
    installationReads(world),
    before + 1,
    "later opens wait for installation_sync_on_open_minutes",
  );
});

test("an empty list is read again before the answer, spaced by installation_reads_now_per_minute", async () => {
  const world = hostedWorld();
  world.github.grant(ALICE, ["acme/api"]);
  const alice = await signIn(world, ALICE);
  world.clock.now += 10_000;
  assert.deepEqual(await liveConfigOf(world, alice), []);
  // Installed on acme with no webhook yet: the next open after the gap finds it.
  world.github.installations.set(11, { account: "acme", repos: ["acme/api"] });
  world.clock.now += 1_000;
  assert.deepEqual(await liveConfigOf(world, alice), [], "within the gap: what the Worker holds");
  world.clock.now += 9_000;
  assert.deepEqual(await liveConfigOf(world, alice), ["acme"]);
});

test("?fresh=1, back from GitHub's install pages, reads GitHub before the answer; plain opens keep their ten minutes", async () => {
  const world = hostedWorld();
  world.github.installations.set(11, { account: "acme", repos: ["acme/api"] });
  world.github.grant(ALICE, ["acme/api", "initech/shared"]);
  const alice = await signIn(world, ALICE);
  world.github.installations.set(33, { account: "initech", repos: ["initech/shared"] });
  world.clock.now += 10_000;
  assert.deepEqual(
    await liveConfigOf(world, alice),
    ["acme"],
    "a plain open answers first and reads later",
  );
  assert.deepEqual(await liveConfigOf(world, alice, "?fresh=1"), ["acme", "initech"]);
  const reads = installationReads(world);
  await liveConfigOf(world, alice, "?fresh=1");
  assert.equal(installationReads(world), reads, "a second fresh read within the gap reads nothing");
});

test("installation_reads_now_per_minute set to off leaves no gap between fresh reads", async () => {
  const world = hostedWorld({ LIMIT_INSTALLATION_READS_NOW_PER_MINUTE: "off" });
  world.github.installations.set(11, { account: "acme", repos: ["acme/api"] });
  world.github.grant(ALICE, ["acme/api"]);
  const alice = await signIn(world, ALICE);
  const reads = installationReads(world);
  await liveConfigOf(world, alice, "?fresh=1");
  await liveConfigOf(world, alice, "?fresh=1");
  assert.equal(installationReads(world), reads + 2);
});

test("a read GitHub doesn't answer in time leaves the config as the Worker holds it", async () => {
  const world = hostedWorld();
  world.github.installations.set(11, { account: "acme", repos: ["acme/api"] });
  world.github.grant(ALICE, ["acme/api"]);
  const alice = await signIn(world, ALICE);
  const fetch = world.services.fetch;
  world.services.fetch = (input, init) =>
    String(input).includes("/user/installations") ? new Promise(() => {}) : fetch(input, init);
  vi.useFakeTimers({ toFake: ["setTimeout"] });
  const request = new Request(`${ORIGIN}/device/config?fresh=1`, bearer(alice));
  const auth = await authenticate(request, world.workerEnv, world.services);
  assert.ok("env" in auth);
  world.clock.now += 10_000;
  const answer = configInstallations(request, auth.session, world.services, () => {});
  await new Promise((resolve) => setImmediate(resolve));
  vi.advanceTimersByTime(8_000);
  assert.deepEqual(
    (await answer)?.map((entry) => entry.account),
    ["acme"],
  );
});

// --- Anthropic key ------------------------------------------------------------------------------------------------

const ALICE_KEY = "alice-anthropic-key-0123456789";

test("a person's own Anthropic key turns AI on for them alone, sealed and never answered back", async () => {
  const { world, alice, bob } = await twoOrgs();
  world.anthropic.valid.add(ALICE_KEY);
  const put = (body: unknown, secret = alice) =>
    world.route("/account/anthropic-key", {
      method: "PUT",
      body: JSON.stringify(body),
      ...bearer(secret),
    });
  assert.equal((await put({ key: "short" })).status, 400);
  assert.equal((await put({ key: "not-a-key-anthropic-takes-000" })).status, 422);
  const saved = await put({ key: ALICE_KEY });
  assert.equal(saved.status, 200);
  assert.deepEqual(
    await saved.json(),
    { anthropic_key: true, ask_ai: false },
    "no App key here: no Ask",
  );
  assert.deepEqual(world.anthropic.provisioned, []);
  assert.equal(
    JSON.stringify([...(world.stores.get("1001")?.map.values() ?? [])]).includes(ALICE_KEY),
    false,
    "sealed at rest",
  );

  const envOf = async (secret: string) => {
    const auth = await authenticate(
      new Request(`${ORIGIN}/prs`, bearer(secret)),
      world.workerEnv,
      world.services,
    );
    assert.ok("env" in auth);
    return auth;
  };
  const aliceAuth = await envOf(alice);
  const bobAuth = await envOf(bob);
  assert.equal(aliceAuth.env.ANTHROPIC_API_KEY, ALICE_KEY);
  assert.equal(bobAuth.env.ANTHROPIC_API_KEY, undefined, "never the operator's key, never Alice's");
  assert.deepEqual(deviceConfig(aliceAuth.env, "alice").features, {
    ask_ai: false,
    key_lines: true,
    rewrite: true,
    feedback: false,
    push: false,
    webhooks: false,
  });
  assert.equal(deviceConfig(bobAuth.env, "bob").features.key_lines, false);
  assert.equal(aliceAuth.session.hasAnthropicKey, true);

  assert.equal(
    (await world.route("/account/anthropic-key", { method: "DELETE", ...bearer(alice) })).status,
    204,
  );
  assert.equal((await envOf(alice)).env.ANTHROPIC_API_KEY, undefined);
  assert.equal((await world.route("/account/anthropic-key", { method: "DELETE" })).status, 401);
});

test("with the App's key, Ask's resources are made in the person's org and Ask turns on", async () => {
  const { world, alice } = await twoOrgs({ GITHUB_APP_ID: "123", GITHUB_APP_PRIVATE_KEY: "pem" });
  world.anthropic.valid.add(ALICE_KEY);
  const saved = await world.route("/account/anthropic-key", {
    method: "PUT",
    body: JSON.stringify({ key: ALICE_KEY }),
    ...bearer(alice),
  });
  assert.deepEqual(await saved.json(), { anthropic_key: true, ask_ai: true });
  assert.deepEqual(world.anthropic.provisioned, [ALICE_KEY]);
  const auth = await authenticate(
    new Request(`${ORIGIN}/prs`, bearer(alice)),
    world.workerEnv,
    world.services,
  );
  assert.ok("env" in auth);
  assert.equal(auth.env.ASK_AGENT_ID, ASK_RESOURCES.agent_id);
  assert.equal(auth.env.ASK_ANTHROPIC_API_KEY, undefined);
  assert.equal(deviceConfig(auth.env, "alice").features.ask_ai, true);
});

test("signing out of the last phone drops the Anthropic key with the tokens", async () => {
  const { world, alice } = await twoOrgs();
  world.anthropic.valid.add(ALICE_KEY);
  await world.route("/account/anthropic-key", {
    method: "PUT",
    body: JSON.stringify({ key: ALICE_KEY }),
    ...bearer(alice),
  });
  await world.route("/auth/signout", { method: "POST", ...bearer(alice) });
  assert.equal(await world.stores.get("1001")?.get("ai"), null);
});

test("with the API-key path off, a key is refused before Anthropic is asked, and removing one still works", async () => {
  const { world, alice } = await twoOrgs({ AI_ON_API_KEY: undefined });
  world.anthropic.valid.add(ALICE_KEY);
  const put = await world.route("/account/anthropic-key", {
    method: "PUT",
    body: JSON.stringify({ key: ALICE_KEY }),
    ...bearer(alice),
  });
  assert.equal(put.status, 409);
  assert.equal(((await put.json()) as { error: { code: string } }).error.code, "api_key_off");
  const removed = await world.route("/account/anthropic-key", {
    method: "DELETE",
    ...bearer(alice),
  });
  assert.equal(removed.status, 204);
});

// --- Per-IP limits ------------------------------------------------------------------------------------------------

test("a per-IP limit set to off counts nothing", async () => {
  const world = hostedWorld({ LIMIT_SIGN_IN_STARTS_PER_IP_PER_MINUTE: "off" });
  for (let attempt = 0; attempt < 30; attempt += 1) {
    assert.equal((await world.route("/auth/github/start?state=x")).status, 400);
  }
  assert.equal(world.limitedIps.size, 0);
});
