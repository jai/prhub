// A PR as GitHub answers for it: the index's GraphQL query (`FIELDS` in src/github.ts), its REST read, and its PolicyBot
// status, with the review week the reads are timed by. For tests and the golden fixtures.
import { pullRequest, reviewWeek } from "../../src/github.ts";
import type { Asked } from "./fake-fetch.ts";

/** Jai's review week: weekdays, 9 to 18 in UTC+7. */
export const REVIEW_WEEK = reviewWeek({
  REVIEW_SLA_UTC_OFFSET_HOURS: "7",
  REVIEW_SLA_HOURS: "9-18",
  REVIEW_SLA_WEEKDAYS: "1,2,3,4,5",
});

/** `prNode` with `overrides`, read as the index reads it for jai. */
export function readPr(overrides: Record<string, unknown> = {}) {
  return pullRequest(prNode(overrides) as never, "jai", false, REVIEW_WEEK, null);
}

/** PolicyBot's status on a PR's head commit, in `state`. */
export const policyBot = (state: string, fields: Record<string, unknown> = {}) => ({
  __typename: "StatusContext",
  context: "policy-bot: main",
  state,
  description: "0/1 rules approved",
  targetUrl: "https://policy.example/details",
  ...fields,
});

export const PR_URL = "https://api.github.com/repos/acme/app/pulls/7";

/** GitHub's REST read of acme/app#7 at `head` on `branch`: its diff when asked for one, else the PR. Null for any other. */
export function pullRequestRest(
  asked: Asked,
  head: string,
  branch = "alex/retry",
): Response | null {
  if (asked.url !== PR_URL) {
    return null;
  }
  return (asked.headers.get("Accept") ?? "").includes("diff")
    ? new Response("diff --git a/x b/x\n")
    : Response.json({
        title: "Sync holidays",
        body: "",
        head: { sha: head, ref: branch },
        base: { ref: "main" },
      });
}

/** An open PR by alex, asked of jai, with one required check passing and one review. Override what a test needs. */
export function prNode(overrides: Record<string, unknown> = {}) {
  return {
    id: "PR_kwDOAcme7",
    number: 7,
    title: "Add the retry to the uploader",
    body: "Retries a failed upload twice.",
    url: "https://github.com/acme/app/pull/7",
    state: "OPEN",
    isDraft: false,
    headRefOid: "504754b2bc3ce5db892dde980e4bc83b60ff7a68",
    headRefName: "alex/retry",
    baseRefName: "main",
    updatedAt: "2026-11-06T09:30:00Z",
    createdAt: "2026-11-05T02:00:00Z",
    additions: 40,
    deletions: 6,
    changedFiles: 3,
    reviewDecision: "REVIEW_REQUIRED",
    mergeable: "MERGEABLE",
    mergeStateStatus: "BLOCKED",
    viewerDidAuthor: false,
    author: {
      __typename: "User",
      login: "alex",
      avatarUrl: "https://avatars.example/alex",
      name: "Alex Doe",
    },
    repository: { nameWithOwner: "acme/app", viewerDefaultMergeMethod: "SQUASH" },
    reviewRequests: {
      nodes: [{ requestedReviewer: { login: "jai", avatarUrl: "https://avatars.example/jai" } }],
    },
    requestEvents: {
      nodes: [{ createdAt: "2026-11-06T03:00:00Z", requestedReviewer: { login: "jai" } }],
    },
    files: {
      nodes: [
        { path: "src/upload.ts", viewerViewedState: "VIEWED" },
        { path: "src/retry.ts", viewerViewedState: "UNVIEWED" },
      ],
    },
    latestReviews: {
      nodes: [
        {
          author: { login: "sam", avatarUrl: "https://avatars.example/sam" },
          state: "COMMENTED",
          submittedAt: "2026-11-06T04:00:00Z",
        },
      ],
    },
    labels: { nodes: [{ name: "backend", color: "0e8a16" }] },
    overall: { nodes: [{ commit: { statusCheckRollup: { state: "SUCCESS" } } }] },
    commits: {
      nodes: [
        {
          commit: {
            statusCheckRollup: {
              contexts: {
                nodes: [
                  {
                    __typename: "CheckRun",
                    name: "test",
                    status: "COMPLETED",
                    conclusion: "SUCCESS",
                    detailsUrl: "https://github.com/acme/app/actions/runs/1",
                    startedAt: "2026-11-06T09:00:00Z",
                    isRequired: true,
                    checkSuite: { workflowRun: { workflow: { name: "ci" } } },
                  },
                ],
              },
            },
          },
        },
      ],
    },
    comments: {
      nodes: [
        {
          id: "IC_1",
          author: { login: "sam", avatarUrl: "https://avatars.example/sam" },
          body: "Looks right.",
          createdAt: "2026-11-06T04:00:00Z",
        },
      ],
    },
    reviews: {
      nodes: [
        {
          id: "PRR_1",
          author: { login: "sam", avatarUrl: "https://avatars.example/sam" },
          state: "COMMENTED",
          body: "",
          submittedAt: "2026-11-06T04:00:00Z",
        },
      ],
    },
    reviewThreads: { nodes: [] },
    viewerLatestReview: null,
    viewerLatestReviewRequest: { id: "RR_1" },
    ...overrides,
  };
}
