import assert from "node:assert/strict";
import { test } from "node:test";
import { claimOf, clientRefOf, SENDING_FOR_MS } from "../src/write-receipts.ts";

test("a write with no receipt goes, a sent one is done, and one being sent waits", () => {
  assert.equal(claimOf(null, 1_000), "go");
  assert.equal(claimOf({ state: "done", at: 0 }, 10 * SENDING_FOR_MS), "done");
  assert.equal(claimOf({ state: "sending", at: 1_000 }, 1_000 + SENDING_FOR_MS - 1), "busy");
});

test("a copy left sending by a Worker that died is sent again", () => {
  assert.equal(claimOf({ state: "sending", at: 0 }, SENDING_FOR_MS), "go");
});

test("a client_ref is 1 to 100 characters, and older builds send none", () => {
  assert.equal(clientRefOf({ client_ref: "a" }), "a");
  assert.equal(clientRefOf({ client_ref: "" }), null);
  assert.equal(clientRefOf({ client_ref: "x".repeat(101) }), null);
  assert.equal(clientRefOf({ kind: "comment" }), null);
  assert.equal(clientRefOf(null), null);
});
