// A PR as GitHub's GraphQL answers the index's query (`FIELDS` in src/github.ts), for tests and the golden fixtures.

/** An open PR by alex, asked of jai, with one required check passing and one review. Override what a test needs. */
export function prNode(overrides: Record<string, unknown> = {}) {
  return {
    id: "PR_kwDOAcme7", number: 7, title: "Add the retry to the uploader", body: "Retries a failed upload twice.",
    url: "https://github.com/acme/app/pull/7", state: "OPEN", isDraft: false,
    headRefOid: "504754b2bc3ce5db892dde980e4bc83b60ff7a68", headRefName: "alex/retry", baseRefName: "main",
    updatedAt: "2026-11-06T09:30:00Z", createdAt: "2026-11-05T02:00:00Z", additions: 40, deletions: 6, changedFiles: 3,
    reviewDecision: "REVIEW_REQUIRED", mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", viewerDidAuthor: false,
    author: { __typename: "User", login: "alex", avatarUrl: "https://avatars.example/alex", name: "Alex Doe" },
    repository: { nameWithOwner: "acme/app", viewerDefaultMergeMethod: "SQUASH" },
    reviewRequests: { nodes: [{ requestedReviewer: { login: "jai", avatarUrl: "https://avatars.example/jai" } }] },
    requestEvents: { nodes: [{ createdAt: "2026-11-06T03:00:00Z", requestedReviewer: { login: "jai" } }] },
    files: { nodes: [
      { path: "src/upload.ts", viewerViewedState: "VIEWED" }, { path: "src/retry.ts", viewerViewedState: "UNVIEWED" },
    ] },
    latestReviews: { nodes: [{ author: { login: "sam", avatarUrl: "https://avatars.example/sam" }, state: "COMMENTED",
      submittedAt: "2026-11-06T04:00:00Z" }] },
    labels: { nodes: [{ name: "backend", color: "0e8a16" }] },
    overall: { nodes: [{ commit: { statusCheckRollup: { state: "SUCCESS" } } }] },
    commits: { nodes: [{ commit: { statusCheckRollup: { contexts: { nodes: [
      { __typename: "CheckRun", name: "test", status: "COMPLETED", conclusion: "SUCCESS",
        detailsUrl: "https://github.com/acme/app/actions/runs/1", startedAt: "2026-11-06T09:00:00Z", isRequired: true,
        checkSuite: { workflowRun: { workflow: { name: "ci" } } } },
    ] } } } }] },
    comments: { nodes: [{ id: "IC_1", author: { login: "sam", avatarUrl: "https://avatars.example/sam" },
      body: "Looks right.", createdAt: "2026-11-06T04:00:00Z" }] },
    reviews: { nodes: [{ id: "PRR_1", author: { login: "sam", avatarUrl: "https://avatars.example/sam" },
      state: "COMMENTED", body: "", submittedAt: "2026-11-06T04:00:00Z" }] },
    reviewThreads: { nodes: [] },
    viewerLatestReview: null, viewerLatestReviewRequest: { id: "RR_1" },
    ...overrides,
  };
}
