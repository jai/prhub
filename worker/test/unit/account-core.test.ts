// The hosted account (`account-core.ts`): its GitHub tokens and their refresh, session lifetimes, and resealing after a
// key rotation, over the in-memory hosted world.
import assert from "node:assert/strict";
import { test } from "vitest";
import { AccountCore, NO_AI, REFRESH_MARGIN_MS } from "../../src/account-core.ts";
import { authenticate, hostedAccountConfig } from "../../src/hosted.ts";
import { parseLimits, WorkerMode } from "../../src/limits.ts";
import { keyIdOf, parseKeyring } from "../../src/token-crypto.ts";
import {
  APP,
  bearer,
  HOUR,
  hostedWorld,
  keyOf,
  MapStore,
  ORIGIN,
  signIn,
} from "../support/hosted-world.ts";

const NOW = Date.parse("2026-11-07T00:00:00Z");

// --- Tokens -------------------------------------------------------------------------------------------------------

test("a token near its 8 hours is refreshed first, once for every request at the same time", async () => {
  const world = hostedWorld();
  await signIn(world);
  const account = world.services.account("4242");
  assert.deepEqual(await account.accessToken(), {
    kind: "ok",
    token: "ghu_1",
    login: "octocat",
    userId: "4242",
    ai: NO_AI,
    linearKey: null,
  });
  assert.equal(world.github.refreshCalls(), 0);
  world.clock.now += 8 * HOUR - REFRESH_MARGIN_MS + 1;
  const answers = await Promise.all([
    account.accessToken(),
    account.accessToken(),
    account.accessToken(),
  ]);
  assert.equal(world.github.refreshCalls(), 1, "two refreshes at once would sign the person out");
  assert.ok(answers.every((answer) => answer.kind === "ok" && answer.token === "ghu_2"));
  assert.equal(world.github.calls.at(-1)?.form?.get("refresh_token"), "ghr_1");
  assert.deepEqual(await account.accessToken(), {
    kind: "ok",
    token: "ghu_2",
    login: "octocat",
    userId: "4242",
    ai: NO_AI,
    linearKey: null,
  });
});

test("a 401 refreshes once; a token another request already replaced is just handed over", async () => {
  const world = hostedWorld();
  await signIn(world);
  const account = world.services.account("4242");
  assert.equal((await account.tokenAfterUnauthorized("ghu_1")).kind, "ok");
  assert.equal(world.github.refreshCalls(), 1);
  const again = await account.tokenAfterUnauthorized("ghu_1");
  assert.deepEqual(again, {
    kind: "ok",
    token: "ghu_2",
    login: "octocat",
    userId: "4242",
    ai: NO_AI,
    linearKey: null,
  });
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
  const auth = await authenticate(
    new Request(`${ORIGIN}/prs`, bearer(secret)),
    world.workerEnv,
    world.services,
  );
  assert.ok("answer" in auth);
  assert.equal(auth.answer.status, 401);
  assert.equal(
    ((await auth.answer.json()) as { error: { code: string } }).error.code,
    "signed_out",
  );
  assert.ok(auth.session);
  assert.deepEqual(hostedAccountConfig(auth.session), {
    hosted: true,
    account: {
      state: "signed_out",
      login: "octocat",
      user_id: "4242",
      anthropic_key: false,
      linear_key: false,
      reason: "revoked",
    },
  });
  assert.equal(
    JSON.stringify([...(world.stores.get("4242")?.map.values() ?? [])]).includes("v1.k1"),
    false,
    "the sealed tokens are gone",
  );
});

test("GitHub down keeps the person signed in and the token while it lives", async () => {
  const world = hostedWorld();
  await signIn(world);
  world.github.refusal = "temporarily_unavailable";
  world.clock.now += 8 * HOUR - REFRESH_MARGIN_MS + 1;
  assert.equal((await world.services.account("4242").accessToken()).kind, "ok");
  world.clock.now += REFRESH_MARGIN_MS;
  assert.equal(
    (await world.services.account("4242").tokenAfterUnauthorized("ghu_1")).kind,
    "unavailable",
  );
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

// --- Sessions -----------------------------------------------------------------------------------------------------

const fingerprintOf = async (secret: string) =>
  Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret))).toString(
    "hex",
  );

test("a session lives session_lifetime_days, and a person keeps sessions_max of them", async () => {
  const world = hostedWorld({ LIMIT_SESSION_LIFETIME_DAYS: "2", LIMIT_SESSIONS_MAX: "2" });
  const first = await signIn(world);
  world.clock.now += 86_400_000;
  const second = await signIn(world);
  const third = await signIn(world);
  const account = world.accounts.get("4242") as AccountCore;
  assert.equal(
    await account.session(await fingerprintOf(first)),
    null,
    "pushed out by sessions_max",
  );
  assert.ok(await account.session(await fingerprintOf(second)));
  world.clock.now += 2 * 86_400_000;
  assert.equal(await account.session(await fingerprintOf(third)), null, "past its lifetime");
  assert.equal(
    (await world.route("/auth/signout", { method: "POST", ...bearer(third) })).status,
    401,
  );
});

// --- Key rotation -------------------------------------------------------------------------------------------------

test("after a key rotation the sweep seals every value again with the new key and reports what moved", async () => {
  const store = new MapStore();
  let raw = `k1:${keyOf(1)}`;
  const account = new AccountCore({
    store,
    keyring: () => parseKeyring(raw),
    app: APP,
    fetch: async () => new Response(null, { status: 500 }),
    now: () => NOW,
    limits: parseLimits({}, WorkerMode.Hosted),
    onSignedOut: async () => {},
  });
  await account.signIn(
    { id: 4242, login: "octocat" },
    {
      access_token: "ghu_old",
      expires_in: 28_800,
      refresh_token: "ghr_old",
      refresh_token_expires_in: 15_897_600,
    } as never,
    "c".repeat(43),
  );
  await account.setAnthropicKey("sk-test-0123456789abcdef", null);
  assert.deepEqual(await account.resealStale(), { current: "k1", resealed: [], stale: [] });

  raw = `k2:${keyOf(2)},k1:${keyOf(1)}`;
  assert.deepEqual(await account.resealStale(), {
    current: "k2",
    resealed: ["access", "refresh", "anthropic"],
    stale: [],
  });
  const held = await store.get<{ tokens: { access: string; refresh: string } }>("account");
  assert.equal(keyIdOf(held?.tokens.access ?? ""), "k2");
  assert.equal(keyIdOf(held?.tokens.refresh ?? ""), "k2");

  raw = `k3:${keyOf(3)}`;
  assert.deepEqual(
    await account.resealStale(),
    {
      current: "k3",
      resealed: [],
      stale: ["access", "refresh", "anthropic"],
    },
    "a key dropped too soon leaves values no key opens, and says so",
  );
});
