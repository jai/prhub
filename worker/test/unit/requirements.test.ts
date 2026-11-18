import assert from "node:assert/strict";
import { test } from "node:test";
import { summaryOf } from "../../src/ai.ts";

const SUMMARY = {
  risk: "low" as const,
  riskWhy: "Small.",
  points: ["One"],
  bugs: [],
  slop: { isSlop: false, tells: [] },
};

test("one ticket: fits is a tick with no gaps, a mismatch keeps up to four gaps", () => {
  const one = { keys: ["CORE-12"], text: "CORE-12: Sync holidays" };
  assert.deepEqual(
    summaryOf({ ...SUMMARY, requirements: { fits: true, gaps: ["ignored"] } }, [], one)
      .requirements,
    { state: "fits", tickets: ["CORE-12"], gaps: [] },
  );
  const gaps = [" No dry run ", "", "B", "C", "D", "E"];
  assert.deepEqual(
    summaryOf({ ...SUMMARY, requirements: { fits: false, gaps } }, [], one).requirements,
    { state: "mismatch", tickets: ["CORE-12"], gaps: ["No dry run", "B", "C", "D"] },
  );
});

test("more than one ticket says so and is not checked; none, or no answer, says nothing", () => {
  const two = { keys: ["CORE-12", "ENG-3"], text: null };
  assert.deepEqual(summaryOf(SUMMARY, [], two).requirements, {
    state: "multiple",
    tickets: ["CORE-12", "ENG-3"],
    gaps: [],
  });
  assert.equal(summaryOf(SUMMARY, [], { keys: [], text: null }).requirements, undefined);
  assert.equal(summaryOf(SUMMARY, [], { keys: ["CORE-12"], text: "t" }).requirements, undefined);
});

test("AI slop keeps up to four tells; a description that isn't slop has none", () => {
  const none = { keys: [], text: null };
  const tells = [" Hype: 'seamless' ", "", "B", "C", "D", "E"];
  assert.deepEqual(summaryOf({ ...SUMMARY, slop: { isSlop: true, tells } }, [], none).slop, {
    isSlop: true,
    tells: ["Hype: 'seamless'", "B", "C", "D"],
  });
  assert.deepEqual(summaryOf({ ...SUMMARY, slop: { isSlop: false, tells } }, [], none).slop, {
    isSlop: false,
    tells: [],
  });
});
