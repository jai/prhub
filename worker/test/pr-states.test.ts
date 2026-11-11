import assert from "node:assert/strict";
import { test } from "node:test";
import { reviewWeek } from "../src/github.ts";
import { parseRefs, stateOf, statesFrom, statesQuery } from "../src/pr-states.ts";

const policyBot = (state: string) => ({ __typename: "StatusContext", context: "policy-bot: main", state });
const check = (conclusion: string) => ({ __typename: "CheckRun", name: "unit", status: "COMPLETED", conclusion });

function node(fields: object = {}, contexts: object[] = [], rollup: string | null = "SUCCESS") {
  return {
    title: "Allow apostrophes", state: "OPEN", isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
    reviewDecision: null, createdAt: "2026-10-24T09:12:00Z", author: { login: "octocat", name: " Mona " },
    latestReviews: { nodes: [] }, reviews: { nodes: [] }, viewerLatestReview: null, viewerLatestReviewRequest: null,
    requestEvents: { nodes: [] },
    overall: { nodes: [{ commit: { statusCheckRollup: rollup ? { state: rollup } : null } }] },
    commits: { nodes: [{ commit: { statusCheckRollup: { contexts: { nodes: contexts } } } }] },
    ...fields,
  } as Parameters<typeof stateOf>[0];
}

test("PolicyBot's word is the review, whatever GitHub's decision says", () => {
  assert.equal(stateOf(node({}, [policyBot("SUCCESS")]), "jai").review, "approved");
  assert.equal(stateOf(node({}, [policyBot("PENDING")]), "jai").review, "required");
  assert.equal(stateOf(node({}, [policyBot("FAILURE")]), "jai").review, "changes_requested");
  assert.equal(stateOf(node(), "jai").review, "none", "no PolicyBot, no decision");
  assert.equal(stateOf(node({ reviewDecision: "REVIEW_REQUIRED" }), "jai").review, "required");
  const held = node({ reviewDecision: "CHANGES_REQUESTED" }, [policyBot("SUCCESS")]);
  assert.equal(stateOf(held, "jai").review, "changes_requested", "PolicyBot can pass while GitHub holds the merge");
});

test("the checks are the required ones, whatever the rollup says", () => {
  const required = (conclusion: string) => ({ ...check(conclusion), isRequired: true });
  const waiting = node({}, [policyBot("PENDING"), required("SUCCESS"), check("FAILURE")], "FAILURE");
  assert.equal(stateOf(waiting, "jai").checks, "passing");
  assert.equal(stateOf(node({}, [required("FAILURE")], "FAILURE"), "jai").checks, "failing");
  assert.equal(stateOf(node({}, [check("FAILURE")], "FAILURE"), "jai").checks, "none", "mergeable: GitHub requires none");
  assert.equal(stateOf(node({}, [], null), "jai").checks, "none");
});

test("state and merge", () => {
  const read = (fields: object) => {
    const { state, merge } = stateOf(node(fields), "jai");
    return [state, merge];
  };
  assert.deepEqual(read({}), ["open", "clean"]);
  assert.deepEqual(read({ isDraft: true, mergeStateStatus: "DRAFT" }), ["draft", "blocked"]);
  assert.deepEqual(read({ mergeable: "CONFLICTING", mergeStateStatus: "BLOCKED" }), ["open", "conflicting"]);
  assert.deepEqual(read({ mergeStateStatus: "BEHIND" }), ["open", "behind"]);
  assert.deepEqual(read({ mergeStateStatus: "SOMETHING_NEW" }), ["open", "unknown"]);
  assert.deepEqual(read({ state: "MERGED" }), ["merged", null]);
  assert.deepEqual(read({ state: "CLOSED", mergeStateStatus: "UNKNOWN" }), ["closed", null]);
});

test("who opened it", () => {
  const one = stateOf(node(), "jai");
  assert.deepEqual([one.author, one.author_name], ["octocat", "Mona"]);
  const gone = stateOf(node({ author: null }), "jai");
  assert.deepEqual([gone.author, gone.author_name], [null, null]);
});

test("Jai's own review: his change request stands, a draft shows, and being asked again is said", () => {
  const review = (state: string, submittedAt: string) => ({ author: { login: "jai" }, state, submittedAt });
  const approved = review("APPROVED", "2026-10-25T09:00:00Z");
  const one = stateOf(node({ latestReviews: { nodes: [approved] } }), "jai");
  assert.deepEqual([one.jai_review, one.jai_reviewed_at, one.jai_review_requested],
    ["approved", "2026-10-25T09:00:00Z", false]);
  const sentBack = node({ reviews: { nodes: [review("CHANGES_REQUESTED", "2026-10-25T09:00:00Z"),
    review("COMMENTED", "2026-10-26T09:00:00Z")] }, viewerLatestReviewRequest: { id: "x" } });
  assert.equal(stateOf(sentBack, "jai").jai_review, "changes_requested");
  assert.equal(stateOf(sentBack, "jai").jai_review_requested, true);
  const draft = stateOf(node({ viewerLatestReview: { state: "PENDING", submittedAt: null } }), "jai");
  assert.deepEqual([draft.jai_review, draft.jai_reviewed_at], ["pending", null]);
  assert.equal(stateOf(node(), "jai").jai_review, null);
});

const WEEK = reviewWeek({
  REVIEW_SLA_UTC_OFFSET_HOURS: "7", REVIEW_SLA_HOURS: "9-18", REVIEW_SLA_WEEKDAYS: "1,2,3,4,5",
});

test("the review's due time is the PRs tab's, and only while review is asked of Jai", () => {
  // Asked on Friday 6 November at 10:00 in UTC+7: due on Monday at 10:00, as the row's `reviewDueAt` says.
  const events = { nodes: [{ createdAt: "2026-11-05T09:00:00Z", requestedReviewer: { login: "jai" } },
    { createdAt: "2026-11-06T03:00:00Z", requestedReviewer: { login: "jai" } },
    { createdAt: "2026-11-07T03:00:00Z", requestedReviewer: { login: "sam" } }] };
  const asked = node({ viewerLatestReviewRequest: { id: "x" }, requestEvents: events });
  assert.equal(stateOf(asked, "jai", WEEK).review_due_at, "2026-11-09T03:00:00Z");
  assert.equal(stateOf(asked, "jai").review_due_at, null, "no SLA week, no due time");
  assert.equal(stateOf(node({ requestEvents: events }), "jai", WEEK).review_due_at, null, "not asked of him now");
  const team = node({ viewerLatestReviewRequest: { id: "x" }, requestEvents: { nodes: [] } });
  assert.equal(stateOf(team, "jai", WEEK).review_due_at, null, "only a team was asked");
  const { aliases } = statesQuery(["jai/trips#1"]);
  assert.equal(statesFrom({ data: { r0: { p0: asked } } }, aliases, "jai", WEEK).states["jai/trips#1"]?.review_due_at,
    "2026-11-09T03:00:00Z");
});

test("no such PR is told from one GitHub wouldn't answer for", () => {
  const { query, aliases } = statesQuery(["jai/trips#1", "jai/trips#2", "jai/gone#3", "acme/app#4"]);
  assert.match(query, /r0: repository\(owner: "jai", name: "trips"\) \{ p0: pullRequest\(number: 1\)/);
  assert.match(query, /isRequired\(pullRequestNumber: 2\)/);
  assert.match(query, /requestEvents: timelineItems\(itemTypes: \[REVIEW_REQUESTED_EVENT\], last: 20\)/);
  const answer = statesFrom({
    data: { r0: { p0: node(), p1: null }, r1: null, r2: { p0: null } },
    errors: [{ type: "NOT_FOUND", path: ["r0", "p1"] }, { type: "NOT_FOUND", path: ["r1"] },
      { type: "FORBIDDEN", path: ["r2", "p0"] }],
  }, aliases, "jai");
  assert.equal(answer.states["jai/trips#1"]?.title, "Allow apostrophes");
  assert.equal(answer.states["jai/trips#2"], null);
  assert.equal(answer.states["jai/gone#3"], null);
  assert.deepEqual(answer.unanswered, ["acme/app#4"]);
});

test("the route takes up to 20 well-formed refs", () => {
  assert.deepEqual(parseRefs({ refs: ["jai/trips#1"] }), ["jai/trips#1"]);
  assert.equal(parseRefs({ refs: [] }), null);
  assert.equal(parseRefs({ refs: ["nope"] }), null);
  assert.equal(parseRefs({ refs: Array(21).fill("jai/trips#1") }), null);
  assert.equal(parseRefs(null), null);
});
