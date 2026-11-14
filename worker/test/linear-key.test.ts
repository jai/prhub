import assert from "node:assert/strict";
import { test } from "node:test";
import { AccountCore } from "../src/account-core.ts";
import { parseKeyring } from "../src/token-crypto.ts";
import { authenticate, hostedAccountConfig } from "../src/hosted.ts";
import { checkLinearKey } from "../src/tickets.ts";
import { APP, bearer, hostedWorld, keyOf, ORIGIN, signIn, KEY } from "./hosted-world.ts";

const key = "lin_api_synthetic012345678901234567890";
const otherKey = "lin_api_synthetic98765432109876543210";

test("connecting Linear validates, seals and uses only that person's key; disconnect and last sign-out erase it", async () => {
  const world = hostedWorld({ LINEAR_API_KEY: "operators-key-must-not-be-used" });
  const secret = await signIn(world);
  const second = await signIn(world, { id: 5555, login: "other" });
  const seen: string[] = [];
  world.services.fetch = async (url, init) => {
    assert.equal(url, "https://api.linear.app/graphql");
    assert.equal(init?.method, "POST");
    seen.push(new Headers(init?.headers).get("Authorization") ?? "");
    return Response.json({ data: { viewer: { id: "linear-person" } } });
  };
  const connect = (secret: string, value: string) => world.route("/account/linear-key", {
    ...bearer(secret), method: "PUT", body: JSON.stringify({ key: value }),
  });
  const first = await connect(secret, key);
  assert.equal(first.status, 200);
  assert.deepEqual(await first.json(), { linear_key: true });
  assert.deepEqual(seen, [key]);
  const stored = await world.stores.get("4242")!.get<string>("linear");
  assert.match(stored!, /^v1\.k1\./);
  assert.equal(stored?.includes(key), false);
  const auth = async (secret: string) => authenticate(new Request(`${ORIGIN}/prs`, bearer(secret)), world.workerEnv, world.services);
  const one = await auth(secret);
  const two = await auth(second);
  assert.ok("env" in one && "env" in two);
  assert.equal(one.env.LINEAR_API_KEY, key);
  assert.equal(two.env.LINEAR_API_KEY, undefined);
  assert.equal(JSON.stringify(hostedAccountConfig(one.session)).includes(key), false);
  assert.equal(one.session.hasLinearKey, true);
  await connect(second, otherKey);
  await world.route("/account/linear-key", { ...bearer(secret), method: "DELETE" });
  assert.equal(await world.stores.get("4242")!.get("linear"), null);
  const stillConnected = await auth(second);
  assert.ok("env" in stillConnected);
  assert.equal(stillConnected.env.LINEAR_API_KEY, otherKey);
  await world.route("/auth/signout", { ...bearer(second), method: "POST" });
  assert.equal(await world.stores.get("5555")!.get("linear"), null);
});

test("refused, malformed and unavailable keys never replace a working connection; a signed-out session cannot change it", async () => {
  const world = hostedWorld();
  const secret = await signIn(world);
  await world.accounts.get("4242")!.setLinearKey(key);
  for (const [value, status, expected] of [["short", 200, 400], [otherKey, 401, 422], [otherKey, 429, 503], [otherKey, 500, 503]] as const) {
    world.services.fetch = async () => Response.json({}, { status });
    const response = await world.route("/account/linear-key", { ...bearer(secret), method: "PUT", body: JSON.stringify({ key: value }) });
    assert.equal(response.status, expected);
    const token = await world.accounts.get("4242")!.accessToken();
    assert.ok(token.kind === "ok");
    assert.equal(token.linearKey, key);
  }
  await world.route("/auth/signout", { ...bearer(secret), method: "POST" });
  for (const method of ["PUT", "DELETE"]) {
    const response = await world.route("/account/linear-key", { ...bearer(secret), method, body: method === "PUT" ? JSON.stringify({ key }) : undefined });
    assert.equal(response.status, 401);
  }
});

test("Linear keys rotate encryption and cannot move to another account", async () => {
  const world = hostedWorld();
  await signIn(world);
  await signIn(world, { id: 5555, login: "other" });
  const account = world.accounts.get("4242")!;
  await account.setLinearKey(key);
  const stored = await world.stores.get("4242")!.get("linear");
  await world.stores.get("5555")!.put("linear", stored);
  const other = await world.accounts.get("5555")!.accessToken();
  assert.ok(other.kind === "ok");
  assert.equal(other.linearKey, null);
  const reopened = new AccountCore({
    store: world.stores.get("4242")!, keyring: () => parseKeyring(`k2:${keyOf(2)},${KEY}`),
    app: APP, fetch: world.github.fetch, now: () => world.clock.now, limits: world.services.limits,
    onSignedOut: async () => {},
  });
  const rotated = await reopened.resealStale();
  assert.ok(rotated?.resealed.includes("linear"));
  assert.match((await world.stores.get("4242")!.get<string>("linear"))!, /^v1\.k2\./);
});

test("Linear GraphQL rejection and transport failures do not become a connected account", async () => {
  assert.equal(await checkLinearKey(key, async () => Response.json({ errors: [{ message: "Authentication required" }] })), "invalid");
  assert.equal(await checkLinearKey(key, async () => { throw new Error("offline"); }), "unavailable");
});
