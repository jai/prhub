import assert from "node:assert/strict";
import { test } from "node:test";
import { parseDelivery, verifySignature } from "../src/webhook.ts";

const encoder = new TextEncoder();

async function sign(body: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const bytes = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(body)));
  return `sha256=${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

test("a signature over the exact body passes, any other does not", async () => {
  const body = encoder.encode('{"a":1}').buffer as ArrayBuffer;
  const header = await sign('{"a":1}', "secret");
  assert.equal(await verifySignature(body, header, "secret"), true);
  assert.equal(await verifySignature(body, header, "other"), false);
  assert.equal(await verifySignature(encoder.encode('{"a":2}').buffer as ArrayBuffer, header, "secret"), false);
  assert.equal(await verifySignature(body, "sha256=nothex", "secret"), false);
  assert.equal(await verifySignature(body, null, "secret"), false);
});

const delivery = (extra: object) => JSON.stringify({
  repository: { full_name: "o/r" },
  pull_request: { number: 7, user: { login: "someone" }, requested_reviewers: [] },
  ...extra,
});

test("a PR by someone else with no request of Jai is a mark that is not involved", () => {
  assert.deepEqual(parseDelivery("pull_request", delivery({}), "jai"), { repo: "o/r", number: 7, involved: false });
});

test("a review request of Jai is involved, in either field GitHub puts it", () => {
  assert.equal(parseDelivery("pull_request", delivery({ requested_reviewer: { login: "jai" } }), "jai")?.involved, true);
  const listed = delivery({ pull_request: { number: 7, requested_reviewers: [{ login: "jai" }] } });
  assert.equal(parseDelivery("pull_request", listed, "jai")?.involved, true);
});

test("Jai's own PR is involved", () => {
  const own = delivery({ pull_request: { number: 7, user: { login: "jai" } } });
  assert.equal(parseDelivery("pull_request_review", own, "jai")?.involved, true);
});

test("a comment on a PR marks it, a comment on an issue does not", () => {
  const comment = (issue: object) => JSON.stringify({ repository: { full_name: "o/r" }, issue });
  assert.deepEqual(parseDelivery("issue_comment", comment({ number: 9, pull_request: {}, user: { login: "x" } }), "jai"),
    { repo: "o/r", number: 9, involved: false });
  assert.equal(parseDelivery("issue_comment", comment({ number: 9, user: { login: "x" } }), "jai"), null);
});

test("events the viewer does not use mark nothing", () => {
  assert.equal(parseDelivery("check_run", delivery({}), "jai"), null);
  assert.equal(parseDelivery("ping", "{}", "jai"), null);
  assert.equal(parseDelivery(null, delivery({}), "jai"), null);
});
