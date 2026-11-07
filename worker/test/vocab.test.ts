import assert from "node:assert/strict";
import { test } from "node:test";
import * as vocab from "../src/vocab.ts";

test("the open lists are the lists without merged", () => {
  assert.deepEqual([...vocab.OPEN_LISTS], vocab.LISTS.filter((list) => list !== "merged"));
});
