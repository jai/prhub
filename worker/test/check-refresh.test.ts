// A checks-only read laid over a held full read (`check-refresh.ts`) says what a full read of the PR would.
import assert from "node:assert/strict";
import { test } from "node:test";
import { patchedRead } from "../src/check-refresh.ts";
import { detailVersionOf, pullRequest, reviewWeek } from "../src/github.ts";
import { POLICY_TTL_MS } from "../src/policy-github.ts";
import type { PeopleDecision } from "../src/policy-people.ts";
import { prNode } from "./pr-node.ts";

const WEEK = reviewWeek({ REVIEW_SLA_UTC_OFFSET_HOURS: "7", REVIEW_SLA_HOURS: "9-18", REVIEW_SLA_WEEKDAYS: "1,2,3,4,5" });
const policyBot = (state: string) => ({ __typename: "StatusContext", context: "policy-bot: main", state,
  description: state === "SUCCESS" ? "Approved by sam" : "1 approval needed", targetUrl: "https://policy/7", isRequired: true });
const check = (name: string, conclusion: string | null) => ({ __typename: "CheckRun", name,
  status: conclusion ? "COMPLETED" : "IN_PROGRESS", conclusion, detailsUrl: `https://ci/${name}`,
  startedAt: "2026-11-06T09:00:00Z", isRequired: true, checkSuite: { workflowRun: { workflow: { name: "ci" } } } });
const contexts = (...nodes: unknown[]) => ({ nodes: [{ commit: { statusCheckRollup: { contexts: { nodes } } } }] });
const NOW = Date.parse("2026-11-06T10:00:00Z");
const overall = (state: string) => ({ nodes: [{ commit: { statusCheckRollup: { state } } }] });

function read(overrides: Record<string, unknown>, people: PeopleDecision | null) {
  const pr = pullRequest(prNode(overrides) as never, "jai", false, WEEK, people);
  assert.ok(pr.status);
  return { ...pr, status: pr.status };
}

test("checks finishing, PolicyBot approving and the merge unblocking read the same as a full read", async () => {
  for (const people of ["APPROVED", "REVIEW_REQUIRED"] as const) {
    const before = read({ commits: contexts(check("test", null), policyBot("PENDING")), overall: overall("PENDING"),
      mergeStateStatus: "BLOCKED" }, people);
    const afterNode = prNode({ commits: contexts(check("test", "SUCCESS"), check("lint", "FAILURE"), policyBot("SUCCESS")),
      overall: overall("FAILURE"), mergeStateStatus: "UNSTABLE" });
    const after = read(afterNode, people);
    const patched = patchedRead({ head: before.head, updatedAt: before.updatedAt, status: before.status,
      detail: before.detail, people, peopleAt: NOW - 60_000 }, afterNode as never, NOW);
    assert.ok(patched);
    assert.deepEqual(patched.status, after.status, `${people}`);
    assert.deepEqual(patched.detail, after.detail, `${people}`);
    assert.equal(patched.version, after.version);
    assert.equal(await detailVersionOf(patched), await detailVersionOf(after), "the phone fetches the same detail");
    assert.notEqual(after.version, before.version, "and the poll's version moves with it, so it marks nothing more");
  }
});

test("a PR whose head or updatedAt moved is read in full", () => {
  const held = read({}, "APPROVED");
  const base = { head: held.head, updatedAt: held.updatedAt, status: held.status, detail: held.detail,
    people: "APPROVED" as const, peopleAt: NOW };
  assert.equal(patchedRead(base, prNode({ headRefOid: "f".repeat(40) }) as never, NOW), null);
  assert.equal(patchedRead(base, prNode({ updatedAt: "2026-11-06T10:00:00Z" }) as never, NOW), null);
  assert.ok(patchedRead(base, prNode() as never, NOW));
});

test("a people decision past the policy TTL, or a null one, is never laid over PolicyBot's live status", () => {
  const held = read({}, "APPROVED");
  const base = { head: held.head, updatedAt: held.updatedAt, status: held.status, detail: held.detail,
    people: "APPROVED" as const, peopleAt: NOW };
  assert.ok(patchedRead(base, prNode() as never, NOW + POLICY_TTL_MS - 1));
  assert.equal(patchedRead(base, prNode() as never, NOW + POLICY_TTL_MS), null, ".policy.yml or a team may have changed");
  assert.equal(patchedRead({ ...base, people: null }, prNode() as never, NOW), null,
    "no decision, or one peopleOf failed to make: the full read tries again");
});
