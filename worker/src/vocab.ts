/**
 * Every fixed set of words the Worker sends about a PR, in one place. Rows, details, `/prs/states` and the stored
 * statuses are typed with these, so a new word is a change here and nowhere else. The four PR sets are the Pager
 * Worker's (`worker/src/threads.ts`), which the app already decodes; `test/vocab.test.ts` pins them to it.
 */

/** GitHub's own state of a PR, a draft as a draft. */
export const PULL_REQUEST_STATES = ["open", "draft", "merged", "closed"] as const;
export type PullRequestState = typeof PULL_REQUEST_STATES[number];

/** What a PR's required checks say, together. */
export const PULL_REQUEST_CHECKS = ["passing", "failing", "pending", "none"] as const;
export type ChecksSummary = typeof PULL_REQUEST_CHECKS[number];

/** Whether GitHub would merge it now. A conflict wins over a merge state that lags (`mergeOf`). */
export const PULL_REQUEST_MERGE_STATES = ["clean", "behind", "blocked", "conflicting", "unstable", "unknown"] as const;
export type MergeState = typeof PULL_REQUEST_MERGE_STATES[number];

/** The review decision, PolicyBot's where a repo has one (`verdictOf`). */
export const PULL_REQUEST_REVIEWS = ["approved", "changes_requested", "required", "none"] as const;
export type ReviewState = typeof PULL_REQUEST_REVIEWS[number];

/**
 * Which list a row is on. `reviewed`: GitHub dropped the request when the user answered it, and the row stays until the
 * PR closes. `merged`: a row of `GET /prs/merged`, never of `GET /prs`.
 */
export const LISTS = ["review", "reviewed", "mine", "merged"] as const;
export type ListKind = typeof LISTS[number];

/** The lists of `GET /prs`: the open PRs. */
export const OPEN_LISTS = ["review", "reviewed", "mine"] as const;
export type OpenList = typeof OPEN_LISTS[number];

/** One check on the detail page. */
export const CHECK_STATES = ["success", "failure", "pending", "skipped"] as const;
export type CheckState = typeof CHECK_STATES[number];

/** PolicyBot's status on the head. */
export const POLICY_STATES = ["approved", "pending", "disapproved", "unknown"] as const;
export type PolicyState = typeof POLICY_STATES[number];
