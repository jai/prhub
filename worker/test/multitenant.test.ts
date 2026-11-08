// The hosted Worker with more than one person: webhook routing by installation, isolation between people, their own
// Anthropic keys, rate limits, and Ask's installation tokens.
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { test } from "node:test";
import { aiStoreKey } from "../src/ai-run.ts";
import { askRepoToken, installationRepoToken } from "../src/app-token.ts";
import { askRecordKey } from "../src/ask-chat.ts";
import { deviceConfig } from "../src/config.ts";
import { aiJobs, type Env, prIndex, scopedKey } from "../src/env.ts";
import { authenticate, canSeeWith, hostedAccountConfig, userEnv } from "../src/hosted.ts";
import { parseRepoFullName, parseSha, type RepoFullName } from "../src/ids.ts";
import { parseAppDelivery } from "../src/installations.ts";
import { gitHubReserveOf, parseLimits, WorkerMode } from "../src/limits.ts";
import { backoffOf, newRateLimitState, observe, stops } from "../src/rate-limit.ts";
import {
  ASK_RESOURCES, bearer, deliver, type FakeUser, hostedWorld, ORIGIN, signIn, type World,
} from "./hosted-world.ts";

const ALICE: FakeUser = { id: 1001, login: "alice" };
const BOB: FakeUser = { id: 2002, login: "bob" };
const SHA = "a".repeat(40);
const RESERVE = gitHubReserveOf(parseLimits({}, WorkerMode.Hosted));
const repo = (name: string) => parseRepoFullName(name) as RepoFullName;

/**
 * Alice works at acme (installation 11), Bob at globex (22), and both at initech (33), where only Alice sees
 * initech/private. acme/secret is in acme's installation, but Alice cannot see it.
 */
async function twoOrgs(vars: Partial<Env> = {}) {
  const world = hostedWorld(vars);
  world.github.installations.set(11, { account: "acme", repos: ["acme/api", "acme/secret"] });
  world.github.installations.set(22, { account: "globex", repos: ["globex/web"] });
  world.github.installations.set(33, { account: "initech", repos: ["initech/shared", "initech/private"] });
  world.github.grant(ALICE, ["acme/api", "initech/shared", "initech/private"]);
  world.github.grant(BOB, ["globex/web", "initech/shared"]);
  const alice = await signIn(world, ALICE);
  const bob = await signIn(world, BOB);
  return { world, alice, bob };
}

const pullRequest = (installation: number, name: string, extra: object = {}) => ({
  action: "synchronize", installation: { id: installation }, sender: { id: 9 }, repository: { full_name: name },
  pull_request: { number: 7, user: { login: "someone" }, requested_reviewers: [] }, ...extra,
});

const marks = (world: World, user: FakeUser) => world.indexes.get(String(user.id))?.marks() ?? [];

async function runChecks(world: World): Promise<void> {
  for (const installation of world.installations.values()) {
    await installation.runChecks(world.clock.now);
  }
}

// --- Routing --------------------------------------------------------------------------------------------------------

test("sign-in joins each installation the person's own token reaches, with the repos it can see there", async () => {
  const { world } = await twoOrgs();
  assert.deepEqual([...(await world.installations.get("11")?.members() ?? new Map()).keys()], ["1001"]);
  assert.deepEqual([...(await world.installations.get("22")?.members() ?? new Map()).keys()], ["2002"]);
  assert.deepEqual([...(await world.installations.get("33")?.members() ?? new Map()).keys()].sort(), ["1001", "2002"]);
  assert.deepEqual(await world.accounts.get("1001")?.installationIds(), ["11", "33"]);
  const listed = world.github.calls.filter((call) => call.url.includes("/user/installations"));
  assert.ok(listed.every((call) => /^Bearer ghu_\d+$/.test(call.headers.get("Authorization") ?? "")),
    "only user tokens read who sees what");
});

test("a delivery for a repo only Alice can see reaches only Alice's index", async () => {
  const { world } = await twoOrgs();
  assert.equal((await deliver(world, "pull_request", pullRequest(11, "acme/api"))).status, 202);
  assert.deepEqual(marks(world, ALICE), ["mark:acme/api#7:false"]);
  assert.deepEqual(marks(world, BOB), []);
});

test("in a shared org each person gets only the repos they see, with their own involvement", async () => {
  const { world } = await twoOrgs();
  await deliver(world, "pull_request", pullRequest(33, "initech/private"));
  await deliver(world, "pull_request", pullRequest(33, "initech/shared", {
    action: "review_requested", requested_reviewer: { login: "bob" },
  }));
  assert.deepEqual(marks(world, ALICE), ["mark:initech/private#7:false", "mark:initech/shared#7:false"]);
  assert.deepEqual(marks(world, BOB), ["mark:initech/shared#7:true"]);
});

test("a repo in the installation the person cannot see is checked with their token once, and never delivered", async () => {
  const { world } = await twoOrgs();
  await deliver(world, "pull_request", pullRequest(11, "acme/secret"));
  assert.deepEqual(marks(world, ALICE), [], "in doubt: nothing until her token answers");
  await runChecks(world);
  assert.deepEqual(marks(world, ALICE), []);
  const asked = world.github.calls.filter((call) => call.url === "https://api.github.com/repos/acme/secret");
  assert.equal(asked.length, 1);
  assert.match(asked[0].headers.get("Authorization") ?? "", /^Bearer ghu_/, "asked with Alice's own token");
  await deliver(world, "pull_request", pullRequest(11, "acme/secret"));
  await runChecks(world);
  assert.equal(world.github.calls.filter((call) => call.url.endsWith("/repos/acme/secret")).length, 1, "the no is kept");
  assert.deepEqual(marks(world, BOB), []);
});

test("a repo added to an installation reaches a member after their token says they see it", async () => {
  const { world } = await twoOrgs();
  world.github.installations.get(11)?.repos.push("acme/new");
  world.github.grant(ALICE, ["acme/new"]);
  world.clock.now += 1_000;
  await deliver(world, "installation_repositories", {
    action: "added", installation: { id: 11 }, sender: { id: 9 }, repositories_added: [{ full_name: "acme/new" }],
    repositories_removed: [],
  });
  await deliver(world, "pull_request", pullRequest(11, "acme/new"));
  assert.deepEqual(marks(world, ALICE), []);
  await runChecks(world);
  assert.deepEqual(marks(world, ALICE), ["mark:acme/new#7:false"]);
  await deliver(world, "pull_request", pullRequest(11, "acme/new"));
  assert.deepEqual(marks(world, ALICE), ["mark:acme/new#7:false", "mark:acme/new#7:false"], "known now: no second ask");
});

const drops = (world: World, user: FakeUser) =>
  world.indexes.get(String(user.id))?.calls.filter((call) => call.startsWith("drop:")) ?? [];

test("a removed repo, a suspended or a deleted installation routes nothing, and drops its rows at once", async () => {
  const { world } = await twoOrgs();
  world.github.installations.set(11, { account: "acme", repos: ["acme/secret"] });
  await deliver(world, "installation_repositories", {
    action: "removed", installation: { id: 11 }, sender: { id: 9 }, repositories_added: [],
    repositories_removed: [{ full_name: "acme/api" }],
  });
  await deliver(world, "pull_request", pullRequest(11, "acme/api"));
  await runChecks(world);
  assert.deepEqual(marks(world, ALICE), []);
  assert.deepEqual(drops(world, ALICE), ["drop:acme/api"]);
  assert.deepEqual(drops(world, BOB), [], "Bob is no member of acme");

  await deliver(world, "installation", { action: "suspend", installation: { id: 33, account: { login: "initech" } } });
  await deliver(world, "pull_request", pullRequest(33, "initech/shared"));
  assert.deepEqual([...marks(world, ALICE), ...marks(world, BOB)], []);
  assert.deepEqual(drops(world, ALICE).at(-1), "drop:initech/private,initech/shared");
  assert.deepEqual(drops(world, BOB), ["drop:initech/private,initech/shared"]);
  await deliver(world, "installation", { action: "unsuspend", installation: { id: 33, account: { login: "initech" } } });
  await deliver(world, "pull_request", pullRequest(33, "initech/shared"));
  assert.equal([...marks(world, ALICE), ...marks(world, BOB)].length, 2);

  await deliver(world, "installation", { action: "deleted", installation: { id: 22, account: { login: "globex" } } });
  await deliver(world, "pull_request", pullRequest(22, "globex/web"));
  await runChecks(world);
  assert.deepEqual(marks(world, BOB), ["mark:initech/shared#7:false"]);
  assert.deepEqual(drops(world, BOB).at(-1), "drop:globex/web");
});

test("check suites and statuses mark the PRs at their head, for members who see the repo", async () => {
  const { world } = await twoOrgs();
  await deliver(world, "check_suite", {
    action: "completed", installation: { id: 33 }, repository: { full_name: "initech/private" },
    check_suite: { head_sha: SHA, pull_requests: [] },
  });
  await deliver(world, "status", {
    installation: { id: 33 }, repository: { full_name: "initech/shared" }, sha: SHA, state: "success",
  });
  assert.deepEqual(marks(world, ALICE), ["head:initech/private@aaaaaaa", "head:initech/shared@aaaaaaa"]);
  assert.deepEqual(marks(world, BOB), ["head:initech/shared@aaaaaaa"]);
});

test("a delivery with the wrong signature or no installation touches nobody", async () => {
  const { world } = await twoOrgs();
  assert.equal((await deliver(world, "pull_request", pullRequest(11, "acme/api"), "not the secret")).status, 401);
  const { installation: _, ...withoutInstallation } = pullRequest(11, "acme/api");
  assert.equal((await deliver(world, "pull_request", withoutInstallation)).status, 202);
  assert.deepEqual([...marks(world, ALICE), ...marks(world, BOB)], []);
});

test("deleting Alice takes her out of every installation and leaves Bob as he was", async () => {
  const { world, alice, bob } = await twoOrgs();
  const answer = await world.route("/account", { method: "DELETE", ...bearer(alice) });
  assert.equal(answer.status, 200);
  assert.deepEqual([...(await world.installations.get("33")?.members() ?? new Map()).keys()], ["2002"]);
  assert.equal((await world.installations.get("11")?.members())?.size, 0);
  const aliceIndex = world.indexes.get("1001");
  const before = aliceIndex?.calls.length;
  await deliver(world, "pull_request", pullRequest(33, "initech/shared"));
  await deliver(world, "pull_request", pullRequest(33, "initech/private"));
  await deliver(world, "pull_request", pullRequest(11, "acme/api"));
  await runChecks(world);
  assert.equal(aliceIndex?.calls.length, before, "no delivery reaches, or makes again, a deleted index");
  assert.deepEqual(marks(world, BOB), ["mark:initech/shared#7:false"]);
  assert.deepEqual(world.deleted, ["1001"], "only Alice's R2 prefix");
  assert.deepEqual(world.forgottenJobs, ["1001"], "no queued AI job of hers runs, or stores an answer, after");
  assert.equal(world.stores.get("1001")?.map.size, 0, "her account holds nothing");
  for (const store of world.installationStores.values()) {
    assert.deepEqual([...store.map.keys()].filter((key) => key.includes("1001")), [], "no installation names her");
  }
  const auth = await authenticate(new Request(`${ORIGIN}/prs`, bearer(bob)), world.workerEnv, world.services);
  assert.ok("env" in auth && auth.env.GITHUB_LOGIN === "bob");
  assert.ok(world.stores.get("2002")?.map.has("account"));
});

test("the person's token decides in doubt: signed out is no, GitHub away or rate limited is ask again", async () => {
  const { world } = await twoOrgs();
  const account = world.services.account("1001");
  assert.equal(await canSeeWith(account, repo("acme/api"), world.github.fetch, world.clock.now, RESERVE), true);
  assert.equal(await canSeeWith(account, repo("acme/secret"), world.github.fetch, world.clock.now, RESERVE), false);
  world.github.headers = { "x-ratelimit-remaining": "0", "x-ratelimit-limit": "5000", "x-ratelimit-reset": "9999999999" };
  const limited = async () => new Response("{}", { status: 403, headers: world.github.headers });
  assert.equal(await canSeeWith(account, repo("acme/secret"), limited, world.clock.now, RESERVE), null);
  const away = async () => new Response("", { status: 502 });
  assert.equal(await canSeeWith(account, repo("acme/secret"), away, world.clock.now, RESERVE), null);
  await account.signOutEverywhere("revoked");
  assert.equal(await canSeeWith(account, repo("acme/api"), world.github.fetch, world.clock.now, RESERVE), false);
});

// --- What the app shows of each installation --------------------------------------------------------------------

/** What `GET /device/config` adds for the session: the account and the installations the last sync read. */
async function configOf(world: World, secret: string) {
  const auth = await authenticate(new Request(`${ORIGIN}/device/config`, bearer(secret)), world.workerEnv,
    world.services);
  assert.ok("env" in auth);
  return hostedAccountConfig(auth.session, await world.services.account(auth.session.userId).installationAccounts()) as
    { installations?: { account: string; suspended: boolean }[] };
}

const accountsOf = async (world: World, secret: string) =>
  (await configOf(world, secret)).installations?.map((entry) => entry.account);

test("/device/config names each installation the person reaches, their own account first, as GitHub has it", async () => {
  const world = hostedWorld();
  world.github.installations.set(44, { account: "Zeta", repos: ["zeta/app"] });
  world.github.installations.set(11, { account: "acme", repos: ["acme/api", "acme/web", "acme/secret"], selection: "selected" });
  world.github.installations.set(55, { account: "alice", repos: ["alice/dotfiles"], type: "User" });
  world.github.installations.set(22, { account: "globex", repos: ["globex/web"] });
  world.github.grant(ALICE, ["zeta/app", "acme/api", "acme/web", "alice/dotfiles"]);
  const alice = await signIn(world, ALICE);
  assert.deepEqual((await configOf(world, alice)).installations, [
    {
      account: "alice", account_type: "User", avatar_url: "https://avatars.githubusercontent.com/u/55?v=4",
      installation_id: 55, repository_selection: "all", suspended: false,
    },
    {
      account: "acme", account_type: "Organization", avatar_url: "https://avatars.githubusercontent.com/u/11?v=4",
      installation_id: 11, repository_selection: "selected", repo_count: 2, suspended: false,
    },
    {
      account: "Zeta", account_type: "Organization", avatar_url: "https://avatars.githubusercontent.com/u/44?v=4",
      installation_id: 44, repository_selection: "all", suspended: false,
    },
  ], "globex is not hers to see; repo_count is what her own token sees of a chosen few");
});

test("installing on a new org shows in the installer's config at once; uninstalling takes it out", async () => {
  const world = hostedWorld();
  world.github.installations.set(11, { account: "acme", repos: ["acme/api"] });
  world.github.grant(ALICE, ["acme/api", "initech/shared"]);
  const alice = await signIn(world, ALICE);
  assert.deepEqual(await accountsOf(world, alice), ["acme"]);

  world.github.installations.set(33, { account: "initech", repos: ["initech/shared"] });
  await deliver(world, "installation", {
    action: "created", installation: { id: 33, account: { login: "initech" } }, sender: { id: ALICE.id },
    repositories: [{ full_name: "initech/shared" }],
  });
  assert.deepEqual(await accountsOf(world, alice), ["acme", "initech"], "no wait for the next sync");

  world.github.installations.delete(33);
  await deliver(world, "installation", {
    action: "deleted", installation: { id: 33, account: { login: "initech" } }, sender: { id: ALICE.id },
  });
  assert.deepEqual(await accountsOf(world, alice), ["acme"]);
});

test("a suspended installation shows as suspended and keeps its members, so the sync still runs", async () => {
  const { world, alice } = await twoOrgs();
  const installation = world.github.installations.get(33);
  assert.ok(installation);
  installation.suspended = true;
  const reposReads = () => world.github.calls.filter((call) => call.url.includes("/user/installations/33/repositories"))
    .length;
  const before = reposReads();
  await deliver(world, "installation", {
    action: "suspend", installation: { id: 33, account: { login: "initech" } }, sender: { id: ALICE.id },
  });
  const listed = (await configOf(world, alice)).installations;
  assert.deepEqual(listed?.map(({ account, suspended }) => [account, suspended]), [["acme", false], ["initech", true]]);
  assert.deepEqual([...(await world.installations.get("33")?.members() ?? new Map()).keys()].sort(), ["1001", "2002"]);
  assert.equal(reposReads(), before, "GitHub lists no repos of a suspended installation, so none are asked for");
});

test("a signed-out session's config, and one before the first sync, name no installations", async () => {
  const world = hostedWorld();
  world.github.installations.set(11, { account: "acme", repos: ["acme/api"] });
  world.github.grant(ALICE, ["acme/api"]);
  const alice = await signIn(world, ALICE);
  await world.stores.get("1001")?.delete(["installation_accounts"]);
  assert.equal("installations" in await configOf(world, alice), false);
  await world.services.account("1001").signOutEverywhere("revoked");
  const auth = await authenticate(new Request(`${ORIGIN}/device/config`, bearer(alice)), world.workerEnv,
    world.services);
  assert.ok("answer" in auth && auth.session);
  assert.equal("installations" in hostedAccountConfig(auth.session, []), false);
});

// --- Isolation of everything a person holds -------------------------------------------------------------------------

test("each person's rows, details, diffs, AI answers, Ask chats and devices live under their own names", () => {
  const named: string[] = [];
  const namespace = { idFromName: (name: string) => named.push(name) && name, get: (id: string) => id };
  const base = { DIFFS: {}, PR_INDEX: namespace, AI_JOBS: namespace } as unknown as Env;
  const a = userEnv(base, { userId: "1001", login: "alice", token: "ghu_a" });
  const b = userEnv(base, { userId: "2002", login: "bob", token: "ghu_b" });
  assert.notEqual(prIndex(a), prIndex(b));
  assert.notEqual(aiJobs(a), aiJobs(b));
  assert.deepEqual(named, ["user:1001", "user:2002", "user:1001", "user:2002"]);
  const pr = repo("acme/api");
  const job = { kind: "key_lines" as const, repo: pr, number: 7, head: parseSha(SHA) ?? (SHA as never), context: 3 };
  for (const [keyA, keyB] of [
    [scopedKey(a, "acme/api/7/x.diff"), scopedKey(b, "acme/api/7/x.diff")],
    [askRecordKey(pr, 7, a), askRecordKey(pr, 7, b)],
    [aiStoreKey(job, a), aiStoreKey(job, b)],
  ]) {
    assert.ok(keyA.startsWith("users/1001/") && keyB.startsWith("users/2002/"), `${keyA} ${keyB}`);
  }
  assert.equal(askRecordKey(pr, 7, base), "ask/acme/api/7.json", "a self-hosted Worker's keys are as they were");
  assert.equal(aiStoreKey(job, base).startsWith("ai/acme/api/7/"), true);
});

// --- Anthropic key --------------------------------------------------------------------------------------------------

const ALICE_KEY = "alice-anthropic-key-0123456789";

test("a person's own Anthropic key turns AI on for them alone, sealed and never answered back", async () => {
  const { world, alice, bob } = await twoOrgs();
  world.anthropic.valid.add(ALICE_KEY);
  const put = (body: unknown, secret = alice) => world.route("/account/anthropic-key", {
    method: "PUT", body: JSON.stringify(body), ...bearer(secret),
  });
  assert.equal((await put({ key: "short" })).status, 400);
  assert.equal((await put({ key: "not-a-key-anthropic-takes-000" })).status, 422);
  const saved = await put({ key: ALICE_KEY });
  assert.equal(saved.status, 200);
  assert.deepEqual(await saved.json(), { anthropic_key: true, ask_ai: false }, "no App key here: no Ask");
  assert.deepEqual(world.anthropic.provisioned, []);
  assert.equal(JSON.stringify([...world.stores.get("1001")?.map.values() ?? []]).includes(ALICE_KEY), false,
    "sealed at rest");

  const envOf = async (secret: string) => {
    const auth = await authenticate(new Request(`${ORIGIN}/prs`, bearer(secret)), world.workerEnv, world.services);
    assert.ok("env" in auth);
    return auth;
  };
  const aliceAuth = await envOf(alice);
  const bobAuth = await envOf(bob);
  assert.equal(aliceAuth.env.ANTHROPIC_API_KEY, ALICE_KEY);
  assert.equal(bobAuth.env.ANTHROPIC_API_KEY, undefined, "never the operator's key, never Alice's");
  assert.deepEqual(deviceConfig(aliceAuth.env, "alice").features,
    { ask_ai: false, key_lines: true, rewrite: true, feedback: false, push: false, webhooks: false });
  assert.equal(deviceConfig(bobAuth.env, "bob").features.key_lines, false);
  assert.equal(aliceAuth.session.hasAnthropicKey, true);

  assert.equal((await world.route("/account/anthropic-key", { method: "DELETE", ...bearer(alice) })).status, 204);
  assert.equal((await envOf(alice)).env.ANTHROPIC_API_KEY, undefined);
  assert.equal((await world.route("/account/anthropic-key", { method: "DELETE" })).status, 401);
});

test("with the App's key, Ask's resources are made in the person's org and Ask turns on", async () => {
  const { world, alice } = await twoOrgs({ GITHUB_APP_ID: "123", GITHUB_APP_PRIVATE_KEY: "pem" });
  world.anthropic.valid.add(ALICE_KEY);
  const saved = await world.route("/account/anthropic-key", {
    method: "PUT", body: JSON.stringify({ key: ALICE_KEY }), ...bearer(alice),
  });
  assert.deepEqual(await saved.json(), { anthropic_key: true, ask_ai: true });
  assert.deepEqual(world.anthropic.provisioned, [ALICE_KEY]);
  const auth = await authenticate(new Request(`${ORIGIN}/prs`, bearer(alice)), world.workerEnv, world.services);
  assert.ok("env" in auth);
  assert.equal(auth.env.ASK_AGENT_ID, ASK_RESOURCES.agent_id);
  assert.equal(auth.env.ASK_ANTHROPIC_API_KEY, undefined);
  assert.equal(deviceConfig(auth.env, "alice").features.ask_ai, true);
});

test("signing out of the last phone drops the Anthropic key with the tokens", async () => {
  const { world, alice } = await twoOrgs();
  world.anthropic.valid.add(ALICE_KEY);
  await world.route("/account/anthropic-key", { method: "PUT", body: JSON.stringify({ key: ALICE_KEY }), ...bearer(alice) });
  await world.route("/auth/signout", { method: "POST", ...bearer(alice) });
  assert.equal(await world.stores.get("1001")?.get("ai"), null);
});

// --- Rate limits ----------------------------------------------------------------------------------------------------

test("sign-in start and finish are limited per IP, each by its own LIMIT_ var, with the limit and wait named", async () => {
  const world = hostedWorld({
    LIMIT_SIGN_IN_STARTS_PER_IP_PER_MINUTE: "2", LIMIT_SIGN_IN_FINISHES_PER_IP_PER_MINUTE: "3",
  });
  const start = (ip: string) => world.route("/auth/github/start?state=x", { headers: { "CF-Connecting-IP": ip } });
  assert.equal((await start("203.0.113.1")).status, 400);
  assert.equal((await start("203.0.113.1")).status, 400);
  const third = await start("203.0.113.1");
  assert.equal(third.status, 429);
  assert.equal(third.headers.get("Retry-After"), "60");
  assert.deepEqual((await third.json() as { error: object }).error, {
    code: "limit_reached", message: "sign_in_starts_per_ip_per_minute reached; try again in 60 s",
    limit: "sign_in_starts_per_ip_per_minute", retry_after: 60,
  });
  assert.equal((await start("203.0.113.2")).status, 400, "another IP has its own count");
  const finish = () => world.route("/auth/github/finish", { method: "POST", headers: { "CF-Connecting-IP": "203.0.113.1" } });
  for (let attempt = 0; attempt < 3; attempt += 1) {
    assert.equal((await finish()).status, 400);
  }
  assert.equal((await finish()).status, 429);
  assert.equal(world.pending.size, 0);
  world.clock.now += 60_000;
  assert.equal((await start("203.0.113.1")).status, 400, "the window passes");
  assert.ok([...world.ipCounts.keys()].every((key) => /^[0-9a-f]{64}$/.test(key)), "an IP is counted by its hash");
});

test("a per-IP limit set to off counts nothing", async () => {
  const world = hostedWorld({ LIMIT_SIGN_IN_STARTS_PER_IP_PER_MINUTE: "off" });
  for (let attempt = 0; attempt < 30; attempt += 1) {
    assert.equal((await world.route("/auth/github/start?state=x")).status, 400);
  }
  assert.equal(world.ipCounts.size, 0);
});

const limitHeaders = (remaining: number, reset = 2_000_000_000, extra: Record<string, string> = {}) => ({
  "x-ratelimit-remaining": String(remaining), "x-ratelimit-limit": "5000", "x-ratelimit-reset": String(reset), ...extra,
});

test("GitHub's rate-limit headers become a backoff: low, none left, or retry-after", () => {
  const now = 1_900_000_000_000;
  const answer = (status: number, headers: Record<string, string>) => new Response(null, { status, headers });
  assert.equal(backoffOf(answer(200, limitHeaders(4_000)), now, RESERVE), null);
  assert.deepEqual(backoffOf(answer(200, limitHeaders(400, 1_900_000_900)), now, RESERVE), { kind: "low", until: 1_900_000_900_000 });
  assert.deepEqual(backoffOf(answer(200, limitHeaders(400)), now, RESERVE), { kind: "low", until: now + 3_600_000 },
    "never past GitHub's hour");
  assert.deepEqual(backoffOf(answer(200, limitHeaders(99, 1_900_000_100)), now, RESERVE), { kind: "low", until: 1_900_000_100_000 });
  assert.deepEqual(backoffOf(answer(403, limitHeaders(0, 1_900_000_100)), now, RESERVE),
    { kind: "primary", until: 1_900_000_100_000 });
  assert.deepEqual(backoffOf(answer(403, limitHeaders(3_000, 1_900_000_100, { "retry-after": "30" })), now, RESERVE),
    { kind: "secondary", until: now + 30_000 });
  assert.deepEqual(backoffOf(answer(429, {}), now, RESERVE), { kind: "secondary", until: now + 60_000 });
  assert.equal(backoffOf(answer(403, {}), now, RESERVE), null, "a plain 403 is a permission, not a limit");
  assert.equal(backoffOf(answer(404, limitHeaders(4_999)), now, RESERVE), null);
});

test("a run keeps its calls and the strictest backoff; low stops only background reads", () => {
  const now = 1_900_000_000_000;
  const state = newRateLimitState();
  observe(state, new Response(null, { headers: limitHeaders(4_000) }), now, RESERVE);
  observe(state, new Response(null, { headers: limitHeaders(300, 1_900_000_500) }), now, RESERVE);
  assert.equal(state.calls, 2);
  assert.equal(state.remaining, 300);
  assert.deepEqual(state.backoff, { kind: "low", until: 1_900_000_500_000 });
  assert.equal(stops(state.backoff, now, true), true);
  assert.equal(stops(state.backoff, now, false), false, "the person's own request still goes");
  assert.equal(stops({ kind: "secondary", until: now + 1 }, now, false), true);
  assert.equal(stops({ kind: "primary", until: now }, now, true), false, "a backoff ends");
});

// --- Deliveries -----------------------------------------------------------------------------------------------------

test("each routed event parses to what it marks, and the rest are ignored", () => {
  const base = { installation: { id: 5 }, repository: { full_name: "o/r" } };
  assert.deepEqual(parseAppDelivery("pull_request", { ...base, pull_request: {
    number: 3, user: { login: "a" }, requested_reviewers: [{ login: "b" }, { name: "team" }] } }),
  { kind: "target", installationId: "5", target: { kind: "pr", repo: "o/r", number: 3, author: "a", reviewers: ["b"] } });
  assert.deepEqual(parseAppDelivery("issue_comment", { ...base, issue: { number: 4, pull_request: {}, user: null } }),
    { kind: "target", installationId: "5", target: { kind: "pr", repo: "o/r", number: 4, author: null, reviewers: [] } });
  assert.equal(parseAppDelivery("issue_comment", { ...base, issue: { number: 4, user: null } }), null, "an issue's");
  assert.deepEqual(parseAppDelivery("status", { ...base, sha: SHA }),
    { kind: "target", installationId: "5", target: { kind: "head", repo: "o/r", sha: SHA } });
  assert.equal(parseAppDelivery("status", { ...base, sha: "nope" }), null);
  assert.equal(parseAppDelivery("check_run", { ...base, check_run: {} }), null);
  assert.equal(parseAppDelivery("pull_request", { repository: { full_name: "o/r" }, pull_request: { number: 1 } }), null,
    "no installation");
  assert.deepEqual(parseAppDelivery("installation", {
    action: "created", installation: { id: 5, account: { login: "acme" } }, sender: { id: 7 },
    repositories: [{ full_name: "acme/x" }, { full_name: "not a repo" }],
  }), { kind: "installation", installationId: "5", action: "created", account: "acme", repos: ["acme/x"], senderId: 7 });
});

// --- Ask's installation token ---------------------------------------------------------------------------------------

const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const PEM = privateKey.export({ type: "pkcs8", format: "pem" }).toString();

function appGitHub() {
  const calls: { url: string; body: unknown; auth: string }[] = [];
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, body: init?.body ? JSON.parse(String(init.body)) : null,
      auth: new Headers(init?.headers).get("Authorization") ?? "" });
    if (url.endsWith("/installation")) {
      return Response.json({ id: 77 });
    }
    return Response.json({ token: "installation-token" }, { status: 201 });
  }) as typeof fetch;
  return { calls, fetcher };
}

test("the hosted Ask token is minted read only, for the one repo", async () => {
  const { calls, fetcher } = appGitHub();
  const token = await installationRepoToken(repo("acme/api"), { id: "123", key: PEM }, true, fetcher);
  assert.equal(token, "installation-token");
  assert.match(calls[0].auth, /^Bearer [\w-]+\.[\w-]+\.[\w-]+$/, "the App's JWT");
  const minted = calls[1].body as { repositories: string[]; permissions: Record<string, string> };
  assert.equal(calls[1].url, "https://api.github.com/app/installations/77/access_tokens");
  assert.deepEqual(minted.repositories, ["api"]);
  assert.ok(Object.values(minted.permissions).every((level) => level === "read"));
});

test("no Ask token is minted for a PR the person's own token cannot read", async () => {
  const real = globalThis.fetch;
  const { calls, fetcher } = appGitHub();
  const asked: string[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    asked.push(`${String(input)} ${new Headers(init?.headers).get("Authorization")}`);
    return String(input).endsWith("/repos/acme/secret/pulls/7") ? new Response("{}", { status: 404 })
      : Response.json({ number: 7 });
  }) as typeof fetch;
  try {
    const person = userEnv({ GITHUB_APP_ID: "123", GITHUB_APP_PRIVATE_KEY: PEM } as Env,
      { userId: "1001", login: "alice", token: "ghu_alice" });
    await assert.rejects(askRepoToken(repo("acme/secret"), 7, person, fetcher), /can't see this pull request/);
    assert.equal(calls.length, 0, "the App was never asked");
    assert.equal(await askRepoToken(repo("acme/api"), 7, person, fetcher), "installation-token");
    assert.deepEqual(asked, [
      "https://api.github.com/repos/acme/secret/pulls/7 Bearer ghu_alice",
      "https://api.github.com/repos/acme/api/pulls/7 Bearer ghu_alice",
    ]);
  } finally {
    globalThis.fetch = real;
  }
});
