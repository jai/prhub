import assert from "node:assert/strict";
import { test } from "node:test";
import { harness, pushBody } from "./fakes.ts";

test("an alert goes to the production host with the contract's headers and the fixed topic", async () => {
  const h = await harness();
  const { key } = await h.issue();
  const response = await h.call("POST", "/v1/push", key, pushBody());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { apns_status: 200, apns_id: "id-1", reason: null });
  const [sent] = h.sent;
  assert.equal(sent!.url, `https://api.push.apple.com/3/device/${"ab".repeat(32)}`);
  assert.equal(sent!.headers["apns-topic"], "com.example.public");
  assert.equal(sent!.headers["apns-push-type"], "alert");
  assert.equal(sent!.headers["apns-priority"], "10");
  assert.equal(sent!.headers["apns-collapse-id"], "alert-1");
  assert.equal(sent!.headers["apns-expiration"], "1767225600");
  assert.match(sent!.headers.authorization!, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.deepEqual(sent!.body, { aps: { alert: { title: "hi" } } });
});

test("a background push to sandbox omits the headers it was not given", async () => {
  const h = await harness();
  const { key } = await h.issue();
  const { collapse_id: _c, expiration: _e, ...body } = pushBody({ apns_env: "sandbox", push_type: "background", priority: 5 });
  await h.call("POST", "/v1/push", key, body);
  const [sent] = h.sent;
  assert.equal(sent!.url, `https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
  assert.equal(sent!.headers["apns-push-type"], "background");
  assert.equal(sent!.headers["apns-priority"], "5");
  assert.ok(!("apns-collapse-id" in sent!.headers));
  assert.ok(!("apns-expiration" in sent!.headers));
});

test("the provider token's header and claims name the key and team", async () => {
  const h = await harness();
  const { key } = await h.issue();
  await h.call("POST", "/v1/push", key, pushBody());
  const [header, claims] = h.sent[0]!.headers.authorization!.slice(7).split(".").slice(0, 2).map((part) =>
    JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/"))),
  );
  assert.deepEqual(header, { alg: "ES256", kid: "KEYID12345" });
  assert.deepEqual(claims, { iss: "TEAM123456", iat: Math.floor(h.clock.ms / 1000) });
});

test("APNs refusals pass through with a 200", async () => {
  const h = await harness({
    apns: () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410, headers: { "apns-id": "id-2" } }),
  });
  const { key } = await h.issue();
  const response = await h.call("POST", "/v1/push", key, pushBody());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { apns_status: 410, apns_id: "id-2", reason: "Unregistered" });
});

test("a body-less APNs error is http_<status>, a thrown fetch is fetch_error", async () => {
  let mode = "500";
  const h = await harness({
    apns: () => {
      if (mode === "throw") throw new TypeError(`network down for ${"ab".repeat(32)}`);
      return new Response("", { status: 500 });
    },
  });
  const { key } = await h.issue();
  assert.deepEqual(await (await h.call("POST", "/v1/push", key, pushBody())).json(), {
    apns_status: 500,
    apns_id: null,
    reason: "http_500",
  });
  mode = "throw";
  assert.deepEqual(await (await h.call("POST", "/v1/push", key, pushBody())).json(), {
    apns_status: null,
    apns_id: null,
    reason: "fetch_error: network",
  });
});

test("the provider token is reused, and re-minted after APNs calls it expired", async () => {
  let refuse = false;
  const h = await harness({
    apns: () =>
      refuse
        ? new Response(JSON.stringify({ reason: "ExpiredProviderToken" }), { status: 403 })
        : new Response(null, { status: 200 }),
  });
  const { key } = await h.issue();
  await h.call("POST", "/v1/push", key, pushBody());
  h.clock.ms += 60_000;
  await h.call("POST", "/v1/push", key, pushBody());
  assert.equal(h.sent[0]!.headers.authorization, h.sent[1]!.headers.authorization);
  refuse = true;
  await h.call("POST", "/v1/push", key, pushBody());
  assert.equal(h.indexStorage.map.has("jwt"), false);
  refuse = false;
  h.clock.ms += 1000;
  await h.call("POST", "/v1/push", key, pushBody());
  assert.notEqual(h.sent[3]!.headers.authorization, h.sent[0]!.headers.authorization);
});

test("a key that cannot be imported is apns_key_invalid, and nothing is sent", async () => {
  const h = await harness({ pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----" });
  const { key } = await h.issue();
  assert.deepEqual(await (await h.call("POST", "/v1/push", key, pushBody())).json(), {
    apns_status: null,
    apns_id: null,
    reason: "apns_key_invalid",
  });
  assert.equal(h.sent.length, 0);
});

test("an invalid body is 400 and does not count against the key", async () => {
  const h = await harness();
  const { key } = await h.issue();
  const response = await h.call("POST", "/v1/push", key, pushBody({ priority: 7 }));
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: "invalid_priority" });
  assert.equal((await h.call("POST", "/v1/push", key, "x".repeat(17 * 1024))).status, 400);
  const listed = (await (await h.call("GET", "/v1/keys", "admin-token-for-tests")).json()) as {
    keys: { sent_24h: number }[];
  };
  assert.equal(listed.keys[0]!.sent_24h, 0);
  assert.equal(h.sent.length, 0);
});

test("the 61st push in a minute is 429 with retry_after, and other keys are unaffected", async () => {
  const h = await harness();
  const first = await h.issue("first");
  const second = await h.issue("second");
  for (let i = 0; i < 60; i++) assert.equal((await h.call("POST", "/v1/push", first.key, pushBody())).status, 200);
  const limited = await h.call("POST", "/v1/push", first.key, pushBody());
  assert.equal(limited.status, 429);
  assert.deepEqual(await limited.json(), { error: "rate_limited", retry_after: 30 });
  assert.equal((await h.call("POST", "/v1/push", second.key, pushBody())).status, 200);
  assert.equal(h.sent.length, 61);
});
