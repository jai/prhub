import assert from "node:assert/strict";
import { test } from "vitest";
import { stateOf } from "../../src/pr-states.ts";
import { prNode, readPr as read } from "../support/pr-node.ts";

test("a row and its detail say the same merge state and review, a lagging merge state among them", () => {
  const cases: [string, string, string][] = [
    ["CONFLICTING", "BEHIND", "conflicting"],
    ["CONFLICTING", "CLEAN", "conflicting"],
    ["MERGEABLE", "BEHIND", "behind"],
    ["MERGEABLE", "CLEAN", "clean"],
    ["UNKNOWN", "BLOCKED", "blocked"],
  ];
  for (const [mergeable, mergeStateStatus, merge] of cases) {
    const pr = read({ mergeable, mergeStateStatus });
    assert.equal(pr.detail.merge, merge, `${mergeable}/${mergeStateStatus}`);
    assert.equal(pr.status?.merge, pr.detail.merge, `${mergeable}/${mergeStateStatus}`);
    assert.equal(pr.status?.review, pr.detail.review);
    assert.equal(
      pr.detail.mergeState,
      mergeStateStatus,
      "the raw state stays for older app builds",
    );
  }
});

test("a draft is on no list, and its detail says blocked as the threads' PR state does", () => {
  const node = prNode({ isDraft: true, mergeStateStatus: "DRAFT" });
  const pr = read({ isDraft: true, mergeStateStatus: "DRAFT" });
  assert.equal(pr.status, null);
  assert.equal(pr.detail.merge, "blocked");
  assert.equal(stateOf(node as never, "jai").merge, pr.detail.merge);
  assert.equal(stateOf(node as never, "jai").review, pr.detail.review);
});

test("the review decision reads as the row's review on the detail", () => {
  assert.equal(read({ reviewDecision: "APPROVED" }).detail.review, "approved");
  assert.equal(read({ reviewDecision: "CHANGES_REQUESTED" }).detail.review, "changes_requested");
  assert.equal(read({ reviewDecision: null }).detail.review, "none");
});
