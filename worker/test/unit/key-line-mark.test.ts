import assert from "node:assert/strict";
import { test } from "vitest";
import { parseKeyLineMark } from "../../src/boundary.ts";
import type { Sha } from "../../src/ids.ts";

const HEAD = "a".repeat(40) as Sha;

test("a mark names a head commit, a key line and whether it is reviewed", () => {
  assert.deepEqual(parseKeyLineMark({ head: HEAD, line: "a:RIGHT:1", reviewed: true }), {
    head: HEAD,
    line: "a:RIGHT:1",
    reviewed: true,
  });
  assert.equal(parseKeyLineMark({ head: "main", line: "a:RIGHT:1", reviewed: true }), null);
  assert.equal(parseKeyLineMark({ head: HEAD, line: "", reviewed: true }), null);
  assert.equal(parseKeyLineMark({ head: HEAD, line: "a".repeat(1_101), reviewed: true }), null);
  assert.equal(parseKeyLineMark({ head: HEAD, line: "a:RIGHT:1", reviewed: "yes" }), null);
  assert.equal(parseKeyLineMark(null), null);
});
