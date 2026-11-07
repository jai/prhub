import assert from "node:assert/strict";
import { test } from "node:test";
import { parseKeyBody, parsePushBody } from "../src/validate.ts";
import { pushBody } from "./fakes.ts";

const parse = (body: unknown) => parsePushBody(JSON.stringify(body));
const errorOf = (body: unknown) => {
  const result = parse(body);
  return result.ok ? null : result.error;
};

test("a full body parses, the device token lowercased", () => {
  const result = parse(pushBody({ device_token: "AB".repeat(32) }));
  assert.ok(result.ok);
  assert.deepEqual(result.value, {
    deviceToken: "ab".repeat(32),
    apnsEnv: "production",
    pushType: "alert",
    priority: 10,
    collapseId: "alert-1",
    expiration: 1767225600,
    payload: { aps: { alert: { title: "hi" } } },
  });
});

test("collapse_id and expiration may be absent or null", () => {
  const { collapse_id: _c, expiration: _e, ...rest } = pushBody();
  for (const body of [rest, { ...rest, collapse_id: null, expiration: null }]) {
    const result = parse(body);
    assert.ok(result.ok);
    assert.equal(result.value.collapseId, null);
    assert.equal(result.value.expiration, null);
  }
});

test("each field is checked", () => {
  assert.equal(errorOf(pushBody({ device_token: "xyz" })), "invalid_device_token");
  assert.equal(errorOf(pushBody({ device_token: "a".repeat(202) })), "invalid_device_token");
  assert.equal(errorOf(pushBody({ device_token: 12 })), "invalid_device_token");
  assert.equal(errorOf(pushBody({ apns_env: "development" })), "invalid_apns_env");
  assert.equal(errorOf(pushBody({ push_type: "voip" })), "invalid_push_type");
  assert.equal(errorOf(pushBody({ priority: 1 })), "invalid_priority");
  assert.equal(errorOf(pushBody({ priority: "10" })), "invalid_priority");
  assert.equal(errorOf(pushBody({ collapse_id: "" })), "invalid_collapse_id");
  assert.equal(errorOf(pushBody({ collapse_id: "x".repeat(65) })), "invalid_collapse_id");
  assert.equal(errorOf(pushBody({ collapse_id: "é".repeat(33) })), "invalid_collapse_id");
  assert.equal(errorOf(pushBody({ expiration: 1.5 })), "invalid_expiration");
  assert.equal(errorOf(pushBody({ expiration: -1 })), "invalid_expiration");
  assert.equal(errorOf(pushBody({ expiration: "1767225600" })), "invalid_expiration");
  assert.equal(errorOf(pushBody({ payload: [] })), "invalid_payload");
  assert.equal(errorOf(pushBody({ payload: { alert: "no aps" } })), "invalid_payload");
});

test("a collapse id of exactly 64 bytes passes", () => {
  assert.ok(parse(pushBody({ collapse_id: "x".repeat(64) })).ok);
});

test("unknown fields, bad JSON and non-objects are refused", () => {
  assert.equal(errorOf(pushBody({ topic: "com.other.app" })), "unknown_field");
  assert.deepEqual(parsePushBody("{"), { ok: false, error: "invalid_json" });
  assert.deepEqual(parsePushBody("[]"), { ok: false, error: "invalid_json" });
});

test("a payload of 4096 bytes passes and 4097 does not", () => {
  const base = JSON.stringify({ aps: {}, pad: "" }).length;
  assert.ok(parse(pushBody({ payload: { aps: {}, pad: "x".repeat(4096 - base) } })).ok);
  assert.equal(errorOf(pushBody({ payload: { aps: {}, pad: "x".repeat(4097 - base) } })), "payload_too_large");
});

test("a key body is a non-empty label and nothing else", () => {
  assert.deepEqual(parseKeyBody('{"label":"  Ann  "}'), { ok: true, value: { label: "Ann" } });
  assert.deepEqual(parseKeyBody('{"label":" "}'), { ok: false, error: "invalid_label" });
  assert.deepEqual(parseKeyBody("{}"), { ok: false, error: "invalid_label" });
  assert.deepEqual(parseKeyBody('{"label":"a","x":1}'), { ok: false, error: "unknown_field" });
});
