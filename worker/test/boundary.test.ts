import assert from "node:assert/strict";
import { test } from "node:test";
import {
  bodyOf, parseAiJob, parseAskInput, parseDeviceEvent, parseDeviceRegistration, parseRowStatus, parseWrite,
} from "../src/boundary.ts";
import { type DeviceIndex, eventRoute, registerRoute, unpairRoute } from "../src/devices.ts";
import type { Fingerprint } from "../src/ids.ts";
import { fingerprintOf, isPairedSecret, parsePairingRecord } from "../src/pairing.ts";

const TOKEN = "ab".repeat(32);
const SECRET = "s".repeat(32);

/** The index's device tables in memory. */
function fakeIndex() {
  const devices = new Map<string, string>();
  const events: { kind: string; detail: object }[] = [];
  const paired = new Set<string>();
  const index: DeviceIndex & { isPaired(fingerprint: Fingerprint): boolean } = {
    registerDevice: (token, host) => devices.set(token, host),
    record: (kind, detail) => events.push({ kind, detail }),
    unpair: (fingerprint) => paired.delete(fingerprint),
    isPaired: (fingerprint) => paired.has(fingerprint),
  };
  return { index, devices, events, paired };
}

function post(body: string, headers: Record<string, string> = {}): Request {
  return new Request("https://worker/device/x", { method: "POST", body, headers });
}

test("a body that isn't JSON is no body, so a route answers 400 rather than throwing", async () => {
  assert.equal(await bodyOf(post("{not json")), null);
  assert.deepEqual(await bodyOf(post('{"a":1}')), { value: { a: 1 } });
  assert.equal(parseWrite((await bodyOf(post("{")))?.value), null);
  assert.equal(parseAskInput((await bodyOf(post("")))?.value), null);
});

test("a junk device token is refused with a 400 and never stored", async () => {
  const { index, devices } = fakeIndex();
  for (const body of [
    JSON.stringify({ token: "not-hex!", host: "production" }),
    JSON.stringify({ token: TOKEN, host: "staging" }),
    JSON.stringify({ token: 42, host: "production" }),
    JSON.stringify({ token: "a".repeat(201), host: "production" }),
    "{",
  ]) {
    assert.equal((await registerRoute(post(body), index)).status, 400, body);
  }
  assert.equal(devices.size, 0);
  assert.equal((await registerRoute(post(JSON.stringify({ token: TOKEN.toUpperCase(), host: "sandbox" })), index)).status, 204);
  assert.deepEqual([...devices], [[TOKEN, "sandbox"]], "kept lowercased, as the relay keeps it");
});

test("a device event is an object with a kind; changed, when sent, a list of ids", async () => {
  const { index, events } = fakeIndex();
  assert.equal((await eventRoute(post(JSON.stringify({ kind: "sync", changed: "acme/app#1" })), index)).status, 400);
  assert.equal((await eventRoute(post(JSON.stringify({ changed: [] })), index)).status, 400);
  assert.equal((await eventRoute(post("[]"), index)).status, 400);
  assert.equal(events.length, 0);
  const sync = { kind: "sync", trigger: "push", rows: 3, changed: ["acme/app#1"], complete: true };
  assert.equal((await eventRoute(post(JSON.stringify(sync)), index)).status, 204);
  assert.deepEqual(events, [{ kind: "sync", detail: { trigger: "push", rows: 3, changed: ["acme/app#1"], complete: true } }]);
  assert.deepEqual(parseDeviceEvent({ kind: "open", milliseconds: 12 }), { kind: "open", detail: { milliseconds: 12 } });
});

test("after an unpair the secret is refused on the very next request", async () => {
  const { index, paired } = fakeIndex();
  const authorization = `Bearer ${SECRET}`;
  paired.add(await fingerprintOf(SECRET));
  assert.equal(await isPairedSecret(authorization, index), true);
  const unpair = new Request("https://worker/device/pair", { method: "DELETE", headers: { Authorization: authorization } });
  assert.equal((await unpairRoute(unpair, index)).status, 204);
  assert.equal(await isPairedSecret(authorization, index), false);
  assert.equal(await isPairedSecret(null, index), false);
});

test("a stored status in an old shape reads as no status", () => {
  const today = {
    list: "review", author: "alex", checks: "passing", review: "required", merge: "clean", jaiReview: null,
    jaiReviewedAt: null, reviewDueAt: "2026-11-07T02:00:00Z",
  };
  assert.deepEqual(parseRowStatus(JSON.stringify(today)), today);
  const { reviewDueAt: _, ...beforeDueTimes } = today;
  assert.equal(parseRowStatus(JSON.stringify(beforeDueTimes)), null);
  assert.equal(parseRowStatus(JSON.stringify({ ...today, list: "archived" })), null);
  assert.equal(parseRowStatus("{"), null);
  assert.equal(parseRowStatus(null), null);
});

test("a queued AI job is read back only in its own shape", () => {
  const job = { kind: "key_lines", repo: "acme/app", number: 7, head: "a".repeat(40), context: 3 };
  assert.deepEqual(parseAiJob(JSON.stringify(job)), job);
  const choice = { model: "claude-haiku-5-5", effort: "low" };
  assert.deepEqual(parseAiJob(JSON.stringify({ ...job, choice }))?.choice, choice);
  assert.equal(parseAiJob(JSON.stringify({ ...job, head: "main" })), null);
  assert.equal(parseAiJob(JSON.stringify({ ...job, choice: { model: "claude-fable-5", effort: "max" } })), null);
  assert.equal(parseAiJob(JSON.stringify({ ...job, kind: "summary" })), null);
  assert.equal(parseAiJob("nope"), null);
});

test("a pairing record from R2 pairs only in its own shape", () => {
  const record = { role: "app", label: "iPad", created_at: "2026-11-07T00:00:00Z", expires_at: "2026-11-07T00:30:00Z" };
  assert.deepEqual(parsePairingRecord(record), record);
  assert.equal(parsePairingRecord({ ...record, role: "owner" }), null);
  assert.equal(parsePairingRecord({ ...record, label: 3 }), null);
});

test("a registration names the APNs host as one of the two", () => {
  assert.equal(parseDeviceRegistration({ token: TOKEN }), null);
  assert.deepEqual(parseDeviceRegistration({ token: TOKEN, host: "production" }), { token: TOKEN, host: "production" });
});
