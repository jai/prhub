import assert from "node:assert/strict";
import { test } from "node:test";
import { constantTimeEqual, sha256Hex } from "../src/keys.ts";
import { ADMIN, harness, pushBody } from "./fakes.ts";

test("constant-time comparison is plain equality", async () => {
  assert.equal(await constantTimeEqual("abc", "abc"), true);
  assert.equal(await constantTimeEqual("abc", "abd"), false);
  assert.equal(await constantTimeEqual("abc", "abcd"), false);
  assert.equal(await constantTimeEqual("", "a"), false);
});

test("admin routes need the admin token", async () => {
  const h = await harness();
  assert.equal((await h.call("GET", "/v1/keys", null)).status, 401);
  assert.equal((await h.call("GET", "/v1/keys", "wrong")).status, 401);
  assert.equal((await h.call("POST", "/v1/keys", "wrong", { label: "x" })).status, 401);
  assert.equal((await h.call("DELETE", "/v1/keys/rk_1", "wrong")).status, 401);
  assert.equal((await h.call("GET", "/v1/keys", ADMIN)).status, 200);
});

test("an unset admin token admits nobody", async () => {
  const h = await harness();
  delete h.env.RELAY_ADMIN_TOKEN;
  assert.equal((await h.call("GET", "/v1/keys", ADMIN)).status, 401);
  assert.equal((await h.call("GET", "/v1/keys", "")).status, 401);
});

test("an issued key is shown once and stored only as its SHA-256", async () => {
  const h = await harness();
  const response = await h.call("POST", "/v1/keys", ADMIN, { label: "Ann's Worker" });
  assert.equal(response.status, 201);
  const { key_id, key } = (await response.json()) as { key_id: string; key: string };
  assert.match(key_id, /^rk_[0-9a-f]{16}$/);
  assert.match(key, /^rks_[A-Za-z0-9_-]{43}$/);
  const stored = JSON.stringify([...h.indexStorage.map.values(), ...[...h.keyStores.instances.keys()]]);
  assert.ok(!stored.includes(key));
  assert.ok(stored.includes(await sha256Hex(key)));
  assert.equal((await h.call("POST", "/v1/keys", ADMIN, { label: "" })).status, 400);
});

test("the list shows labels, use and the day's count, never the keys", async () => {
  const h = await harness();
  const first = await h.issue("first");
  h.clock.ms += 1000;
  await h.issue("second");
  await h.call("POST", "/v1/push", first.key, pushBody());
  await h.call("POST", "/v1/push", first.key, pushBody());
  const listed = (await (await h.call("GET", "/v1/keys", ADMIN)).json()) as { keys: Record<string, unknown>[] };
  assert.deepEqual(
    listed.keys.map((k) => [k.label, k.sent_24h, k.last_used_at !== null]),
    [["first", 2, true], ["second", 0, false]],
  );
  assert.deepEqual(Object.keys(listed.keys[0]!).sort(), ["created_at", "key_id", "label", "last_used_at", "sent_24h"]);
  assert.ok(!JSON.stringify(listed).includes(first.key));
});

test("a revoked key gets 401 and leaves the list; an unknown id is 404", async () => {
  const h = await harness();
  const { key_id, key } = await h.issue();
  assert.equal((await h.call("POST", "/v1/push", key, pushBody())).status, 200);
  assert.equal((await h.call("DELETE", `/v1/keys/${key_id}`, ADMIN)).status, 204);
  assert.equal((await h.call("POST", "/v1/push", key, pushBody())).status, 401);
  const listed = (await (await h.call("GET", "/v1/keys", ADMIN)).json()) as { keys: unknown[] };
  assert.equal(listed.keys.length, 0);
  assert.equal((await h.call("DELETE", `/v1/keys/${key_id}`, ADMIN)).status, 404);
});

test("pushes need a live relay key", async () => {
  const h = await harness();
  assert.equal((await h.call("POST", "/v1/push", null, pushBody())).status, 401);
  assert.equal((await h.call("POST", "/v1/push", ADMIN, pushBody())).status, 401);
  assert.equal((await h.call("POST", "/v1/push", "rks_unknown", pushBody())).status, 401);
  // A bad body from a bad key is still 401: nothing about the shape is told to a stranger.
  assert.equal((await h.call("POST", "/v1/push", "rks_unknown", "{")).status, 401);
  assert.equal(h.sent.length, 0);
});

test("unknown routes and methods", async () => {
  const h = await harness();
  assert.equal((await h.call("GET", "/", null)).status, 404);
  assert.equal((await h.call("GET", "/v1/push", null)).status, 405);
  assert.equal((await h.call("PUT", "/v1/keys", ADMIN)).status, 405);
});
