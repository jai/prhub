import assert from "node:assert/strict";
import { test } from "node:test";
import {
  checkOf, requiredChecks, detailState, jaiReview, latestChecks, listOf, policyOf, reviewDecisionOf, reviewersOf, revisionOf, rowStatus, mergeOf, mergedRow, reviewDueAt, reviewRequestedAt, reviewWeek } from "../src/github.ts";

/** Jai's vars in pr-worker/wrangler.jsonc. */
const JAI_WEEK = reviewWeek({ REVIEW_SLA_UTC_OFFSET_HOURS: "7", REVIEW_SLA_HOURS: "9-18", REVIEW_SLA_WEEKDAYS: "1,2,3,4,5" });

const pr = { state: "OPEN", isDraft: false, author: { __typename: "User", login: "someone" },
  reviewRequests: { nodes: [] as { requestedReviewer: { login?: string } | null }[] },
  latestReviews: { nodes: [] as { author: { login: string } | null; state: string; submittedAt: string | null }[] } };
const reviewed = { nodes: [{ author: { login: "jai" }, state: "APPROVED", submittedAt: "2026-11-01T01:00:00Z" }] };

test("a PR Jai answered stays on his list until it closes, and only if it was on it", () => {
  const answered = { ...pr, latestReviews: reviewed };
  assert.equal(listOf(answered, "jai", true), "reviewed");
  assert.equal(listOf(answered, "jai", false), null);
  assert.equal(listOf(pr, "jai", true), null);
  assert.equal(listOf({ ...answered, state: "MERGED" }, "jai", true), null);
  const draft = { nodes: [{ ...reviewed.nodes[0], state: "PENDING" }] };
  assert.equal(listOf({ ...pr, latestReviews: draft }, "jai", true), null);
});

test("asked again, a reviewed PR goes back to the review list", () => {
  const requested = { nodes: [{ requestedReviewer: { login: "jai" } }] };
  assert.equal(listOf({ ...pr, latestReviews: reviewed, reviewRequests: requested }, "jai", true), "review");
});

test("a change request stands when he is asked again, comments over it, or GitHub leaves him out", () => {
  const review = (state: string, submittedAt: string) => ({ author: { login: "jai" }, state, submittedAt });
  const sentBack = review("CHANGES_REQUESTED", "2026-10-25T09:27:36Z");
  const latest = (nodes: unknown[]) => ({ nodes }) as Parameters<typeof listOf>[0]["latestReviews"];
  const requested = { nodes: [{ requestedReviewer: { login: "jai" } }] };
  const asked = { ...pr, reviewRequests: requested, latestReviews: latest([]) };
  assert.equal(jaiReview({ ...asked, reviews: { nodes: [sentBack] } }, "jai"), sentBack);

  const comment = review("COMMENTED", "2026-10-26T09:00:00Z");
  assert.equal(jaiReview({ latestReviews: latest([comment]), reviews: { nodes: [sentBack, comment] } }, "jai"), sentBack);

  const approval = review("APPROVED", "2026-10-27T09:00:00Z");
  assert.equal(jaiReview({ latestReviews: latest([approval]), reviews: { nodes: [sentBack, approval] } }, "jai"), approval);
  const dismissed = review("DISMISSED", "2026-10-25T09:27:36Z");
  assert.equal(jaiReview({ latestReviews: latest([dismissed]), reviews: { nodes: [dismissed] } }, "jai"), dismissed);
  assert.equal(jaiReview({ ...asked, reviews: { nodes: [approval] } }, "jai"), approval, "asked again after approving");
  assert.equal(jaiReview({ ...asked, reviews: { nodes: [review("PENDING", "")] } }, "jai"), undefined);
});

test("a change request outranks a PolicyBot pass or wait", () => {
  assert.equal(reviewDecisionOf(policyOf([policyBot("SUCCESS")]), "CHANGES_REQUESTED"), "CHANGES_REQUESTED");
  assert.equal(reviewDecisionOf(policyOf([policyBot("PENDING")]), "CHANGES_REQUESTED"), "CHANGES_REQUESTED");
});

test("a check run again shows once, as its latest run", () => {
  const run = (name: string, workflow: string, conclusion: string | null, startedAt: string | null) => ({
    __typename: "CheckRun", name, conclusion, startedAt, status: conclusion ? "COMPLETED" : "QUEUED",
    checkSuite: { workflowRun: { workflow: { name: workflow } } },
  });
  const states = (contexts: ReturnType<typeof run>[]) =>
    latestChecks(contexts).map((context) => [context.name, checkOf(context).state]);

  assert.deepEqual(states([
    run("gate", "Meta", "FAILURE", "2026-11-04T11:39:00Z"), run("gate", "Meta", "SUCCESS", "2026-11-04T12:33:00Z"),
    run("gate", "Meta", "CANCELLED", "2026-11-04T11:38:00Z"),
  ]), [["gate", "success"]]);
  assert.deepEqual(states([
    run("gate", "Meta", "SUCCESS", "2026-11-04T12:33:00Z"), run("gate", "Meta", null, null),
  ]), [["gate", "pending"]], "a run that hasn't started replaces the one before it");
  assert.deepEqual(states([
    run("gate", "Meta", "SUCCESS", "2026-11-04T12:33:00Z"), run("gate", "Harness", "FAILURE", "2026-11-04T11:00:00Z"),
  ]), [["gate", "success"], ["gate", "failure"]], "the same name in another workflow is another check");
});

test("a row carries Jai's own review", () => {
  const status = rowStatus("reviewed", "someone", "SUCCESS", null, "CLEAN", reviewed.nodes[0]);
  assert.equal(status.jaiReview, "approved");
  assert.equal(status.jaiReviewedAt, "2026-11-01T01:00:00Z");
});

const unit = { __typename: "CheckRun", name: "unit", status: "COMPLETED", conclusion: "SUCCESS" };
const policyBot = (state: string) => ({ __typename: "StatusContext", context: "policy-bot: main", state,
  description: "0/1 rules approved", targetUrl: "https://policy.example/details" });

test("PolicyBot waiting on a person is not a check running, and is a review required", () => {
  const contexts = [unit, policyBot("PENDING")];
  const policy = policyOf(contexts);
  assert.deepEqual(policy, { state: "pending", description: "0/1 rules approved", url: "https://policy.example/details", required: false });
  assert.equal(requiredChecks([{ ...unit, isRequired: true }, { ...policyBot("PENDING"), isRequired: true }]), "SUCCESS");
  assert.equal(reviewDecisionOf(policy, null), "REVIEW_REQUIRED");
});

test("PolicyBot outranks GitHub's decision, and a repo without it keeps GitHub's", () => {
  assert.equal(reviewDecisionOf(policyOf([policyBot("FAILURE")]), "APPROVED"), "CHANGES_REQUESTED");
  assert.equal(reviewDecisionOf(policyOf([policyBot("SUCCESS")]), null), "APPROVED");
  assert.equal(reviewDecisionOf(policyOf([unit]), "APPROVED"), "APPROVED");
});

test("only required checks speak for a PR", () => {
  const required = { ...unit, isRequired: true };
  const state = (conclusion: string | null, status = "COMPLETED") => ({ ...required, conclusion, status });
  assert.equal(requiredChecks([state("FAILURE")]), "FAILURE");
  assert.equal(requiredChecks([state(null, "IN_PROGRESS")]), "PENDING");
  assert.equal(requiredChecks([state("SKIPPED")]), "SUCCESS");
  assert.equal(requiredChecks([state("CANCELLED")]), "FAILURE", "GitHub is waiting on it, so the merge is held");
  const optional = { ...unit, name: "lint", conclusion: "FAILURE" };
  assert.equal(requiredChecks([required, optional]), "SUCCESS", "one nobody requires doesn't hold the merge");
  assert.equal(requiredChecks([optional, { ...optional, conclusion: "CANCELLED" }]), null, "nothing required, nothing to say");
  assert.equal(requiredChecks([{ ...policyBot("PENDING"), isRequired: true }]), null, "PolicyBot is the review");
});

test("a required check run again counts by its latest run", () => {
  const run = (conclusion: string, startedAt: string) => ({ ...unit, isRequired: true, conclusion, startedAt });
  const passedLast = [run("SUCCESS", "2026-11-04T10:00:00Z"), run("FAILURE", "2026-11-04T09:00:00Z")];
  assert.equal(requiredChecks(passedLast), "SUCCESS");
  assert.equal(requiredChecks([...passedLast].reverse()), "SUCCESS");
  assert.equal(requiredChecks([run("SUCCESS", "2026-11-04T09:00:00Z"), run("CANCELLED", "2026-11-04T10:00:00Z")]), "FAILURE");
});

test("a check says whether it is required, and cancelled only matters then", () => {
  const cancelled = { ...unit, conclusion: "CANCELLED" };
  assert.deepEqual(checkOf(cancelled), { name: "unit", state: "skipped", url: null, required: false });
  assert.deepEqual(checkOf({ ...cancelled, isRequired: true }), { name: "unit", state: "failure", url: null, required: true });
});

test("the reviewers are who reviewed, then who is waited on, once each", () => {
  const reviewers = reviewersOf({
    reviewRequests: { nodes: [{ requestedReviewer: { login: "ann" } }, { requestedReviewer: { name: "platform" } }] },
    latestReviews: { nodes: [
      { author: { login: "ann" }, state: "APPROVED", submittedAt: null },
      { author: { login: "bob" }, state: "APPROVED", submittedAt: null },
    ] },
  });
  assert.deepEqual(reviewers.map(({ login, state }) => `${login}:${state}`),
    ["bob:APPROVED", "ann:REQUESTED", "platform:REQUESTED"]);
});

test("a review request of Jai puts a PR on the review list, even his own", () => {
  const requested = { nodes: [{ requestedReviewer: { login: "jai" } }] };
  assert.equal(listOf({ ...pr, reviewRequests: requested }, "jai"), "review");
});

test("Jai's own PR is on his list, anyone else's with no request is on neither", () => {
  assert.equal(listOf({ ...pr, author: { __typename: "User", login: "jai" } }, "jai"), "mine");
  assert.equal(listOf(pr, "jai"), null);
});

test("closed, draft and bot PRs are on neither list", () => {
  const own = { ...pr, author: { __typename: "User", login: "jai" } };
  assert.equal(listOf({ ...own, state: "MERGED" }, "jai"), null);
  assert.equal(listOf({ ...own, isDraft: true }, "jai"), null);
  assert.equal(listOf({ ...pr, author: { __typename: "Bot", login: "jai" } }, "jai"), null);
});

test("a retarget changes the revision, and a branch name stays safe in a file name", () => {
  assert.equal(revisionOf("abc", "main"), "abc-main");
  assert.equal(revisionOf("abc", "feature/one two"), "abc-feature_one_two");
});

test("check runs and commit statuses read as one shape", () => {
  const run = (status: string, conclusion: string | null) =>
    checkOf({ __typename: "CheckRun", name: "ci", status, conclusion, detailsUrl: "u" });
  assert.deepEqual(run("COMPLETED", "SUCCESS"), { name: "ci", state: "success", url: "u" , required: false});
  assert.equal(run("COMPLETED", "SKIPPED").state, "skipped");
  assert.equal(run("COMPLETED", "CANCELLED").state, "skipped");
  assert.equal(run("COMPLETED", "FAILURE").state, "failure");
  assert.equal(run("IN_PROGRESS", null).state, "pending");
  const status = checkOf({ __typename: "StatusContext", context: "policy", state: "PENDING", targetUrl: null });
  assert.deepEqual(status, { name: "policy", state: "pending", url: null , required: false});
  assert.equal(checkOf({ __typename: "StatusContext", context: "p", state: "ERROR" }).state, "failure");
});

test("a merge state speaks the app's vocabulary, and anything else reads as nothing known", () => {
  assert.equal(mergeOf("UNKNOWN", "DIRTY"), "conflicting");
  assert.equal(mergeOf("CONFLICTING", "BLOCKED"), "conflicting");
  assert.equal(mergeOf("MERGEABLE", "NEW_STATE"), "unknown");
  assert.deepEqual(rowStatus("mine", null, "none", "none", "unknown"),
    { list: "mine", author: null, checks: "none", review: "none", merge: "unknown", jaiReview: null,
    jaiReviewedAt: null, reviewDueAt: null });
});

test("a detail says GitHub's state, a draft as a draft", () => {
  assert.equal(detailState({ state: "OPEN", isDraft: false }), "open");
  assert.equal(detailState({ state: "OPEN", isDraft: true }), "draft");
  assert.equal(detailState({ state: "MERGED", isDraft: false }), "merged");
  assert.equal(detailState({ state: "CLOSED", isDraft: false }), "closed");
});

test("Jai's review is due one Bangkok working day after he can first see the request", () => {
  // Thursday 10:00 in Bangkok: Friday 10:00.
  assert.equal(reviewDueAt("2026-11-05T03:00:00Z", JAI_WEEK), "2026-11-06T03:00:00Z");
  // Friday 10:00: Monday 10:00, past the weekend.
  assert.equal(reviewDueAt("2026-11-06T03:00:00Z", JAI_WEEK), "2026-11-09T03:00:00Z");
  // Thursday 20:00, after hours: the day starts Friday 09:00, so Monday 09:00.
  assert.equal(reviewDueAt("2026-11-05T13:00:00Z", JAI_WEEK), "2026-11-09T02:00:00Z");
  // Saturday: the day starts Monday 09:00, so Tuesday 09:00.
  assert.equal(reviewDueAt("2026-11-07T05:00:00Z", JAI_WEEK), "2026-11-10T02:00:00Z");
  // Thursday 07:00, before hours: Thursday 09:00 opens it, so Friday 09:00.
  assert.equal(reviewDueAt("2026-11-05T00:00:00Z", JAI_WEEK), "2026-11-06T02:00:00Z");
  assert.equal(reviewDueAt(null, JAI_WEEK), null);
});

test("the review week comes from the three SLA vars, and is off when any is unset or makes no sense", () => {
  assert.deepEqual(JAI_WEEK, { offsetHours: 7, startHour: 9, endHour: 18, weekdays: [1, 2, 3, 4, 5] });
  assert.deepEqual(reviewWeek({ REVIEW_SLA_UTC_OFFSET_HOURS: "-5", REVIEW_SLA_HOURS: " 8 - 17 ", REVIEW_SLA_WEEKDAYS: "0, 1" }),
    { offsetHours: -5, startHour: 8, endHour: 17, weekdays: [0, 1] });
  assert.equal(reviewWeek({}), null);
  assert.equal(reviewWeek({ REVIEW_SLA_UTC_OFFSET_HOURS: "7", REVIEW_SLA_HOURS: "9-18", REVIEW_SLA_WEEKDAYS: "" }), null);
  assert.equal(reviewWeek({ REVIEW_SLA_UTC_OFFSET_HOURS: "7", REVIEW_SLA_HOURS: "18-9", REVIEW_SLA_WEEKDAYS: "1" }), null);
  assert.equal(reviewWeek({ REVIEW_SLA_UTC_OFFSET_HOURS: "x", REVIEW_SLA_HOURS: "9-18", REVIEW_SLA_WEEKDAYS: "1" }), null);
  assert.equal(reviewWeek({ REVIEW_SLA_UTC_OFFSET_HOURS: "7", REVIEW_SLA_HOURS: "9-18", REVIEW_SLA_WEEKDAYS: "1,7" }), null);
});

test("without a review week no request is ever due", () => {
  assert.equal(reviewDueAt("2026-11-05T03:00:00Z", null), null);
});

test("the latest request of Jai himself starts the clock; a team's request starts none", () => {
  const events = [
    { createdAt: "2026-11-01T01:00:00Z", requestedReviewer: { login: "jai" } },
    { createdAt: "2026-11-03T01:00:00Z", requestedReviewer: { login: "jai" } },
    { createdAt: "2026-11-04T01:00:00Z", requestedReviewer: { login: "ann" } },
    { createdAt: "2026-11-05T01:00:00Z", requestedReviewer: {} },
  ];
  assert.equal(reviewRequestedAt(events, "jai"), "2026-11-03T01:00:00Z");
  assert.equal(reviewRequestedAt(events.slice(2), "jai"), null);
  assert.equal(rowStatus("reviewed", null, "none", "none", "unknown", undefined, "2026-11-06T03:00:00Z").reviewDueAt, null);
});

test("a merged PR is a row of its own list, its diff refused only where GitHub would refuse it", () => {
  const node = { number: 9, title: "t", headRefOid: "a".repeat(40), baseRefName: "main", updatedAt: "2026-11-01T00:00:00Z",
    mergedAt: "2026-11-01T00:00:00Z", additions: 10, deletions: 2, changedFiles: 3, author: { login: "jai" },
    repository: { nameWithOwner: "o/r" } };
  const row = mergedRow(node);
  assert.equal(row.status.list, "merged");
  assert.equal(row.status.mergedAt, "2026-11-01T00:00:00Z");
  assert.equal(row.diff, "ready");
  assert.equal(row.detail, "2026-11-01T00:00:00Z.MERGED");
  assert.equal(mergedRow({ ...node, changedFiles: 301 }).diff, "too_large");
});
