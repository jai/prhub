import { type Env, githubLogin, isSet } from "./env.ts";
import { renewAfterUnauthorized } from "./hosted.ts";
import { gitHubReserveOf, limitsOf } from "./limits.ts";
import { backoffOf, heldBackoff, holdBackoff, observe, stops, waitAnswer } from "./rate-limit.ts";
import {
  parseSha, prId, type PrId, repoOf, type RepoFullName, repoParts, type Revision, revisionOf, type Sha, shaOf,
} from "./ids.ts";
import { type GitHubCache, peopleOf } from "./policy-github.ts";
import { PEOPLE_FIELDS, type PeopleDecision, type PeopleNode } from "./policy-people.ts";
import { botAuthorsOf, isBotAuthor, type RequestedBy, requestedByOf } from "./requester.ts";
import {
  allKeys, lookUpTickets, resolvedTickets, rowTickets, type Ticket, type TicketKeys, ticketKeysOf,
} from "./tickets.ts";
import type {
  CheckState, ChecksSummary, MergeState, OpenList, PolicyState, PullRequestState, ReviewState,
} from "./vocab.ts";

export type { CheckState };

/** What a search says about a PR: enough to tell whether the index is behind. */
export interface Listing {
  id: PrId;
  repo: RepoFullName;
  number: number;
  version: string;
  /** Found only by the search for what Jai reviewed. */
  reviewedOnly: boolean;
}

export interface PullRequestRef {
  id: PrId;
  repo: RepoFullName;
  number: number;
}

interface Author {
  login: string;
  avatarUrl: string;
}

interface Comment {
  id: string;
  author: Author | null;
  body: string;
  createdAt: string;
}

interface Rollup {
  contexts: { nodes: {
    __typename: string;
    name?: string;
    context?: string;
    status?: string;
    conclusion?: string | null;
    state?: string;
    description?: string | null;
    detailsUrl?: string | null;
    targetUrl?: string | null;
    startedAt?: string | null;
    isRequired?: boolean;
    checkSuite?: { workflowRun: { workflow: { name: string } } | null } | null;
  }[] };
}

type Context = Rollup["contexts"]["nodes"][number];

export interface Check {
  name: string;
  state: CheckState;
  url: string | null;
  /** GitHub holds the merge for this check. */
  required: boolean;
  /** The Actions workflow that ran it; null for a commit status or an app's check. The app tells same-named checks apart
   * by it and groups a job's matrix legs within it. */
  workflow: string | null;
}

/** PolicyBot's status on the head, in its own words. The reasons stay on the page `url` opens. */
export interface Policy {
  state: PolicyState;
  description: string | null;
  url: string | null;
  /** GitHub holds the merge for it. */
  required: boolean;
}

/** One person on a PR's review: their latest review's state, or `REQUESTED` while they are waited on. */
export interface Reviewer {
  login: string;
  avatarUrl: string | null;
  state: string;
}

/** Everything the phone shows about a PR but its diff. */
export interface Detail {
  id: string;
  url: string;
  state: PullRequestState;
  head: string;
  base: string;
  headBranch: string;
  author: (Author & { __typename: string; name?: string | null }) | null;
  isAuthor: boolean;
  /** The author is a bot (`isBotAuthor`): a GitHub App, a `[bot]` login, or an account `BOT_AUTHORS` names. */
  authorIsBot: boolean;
  /** The human a bot opened it for, where one is recorded (`requestedByOf`); null for a person's own PR. */
  requestedBy: RequestedBy | null;
  /** The Linear issues its title (in brackets), branch and description name, as Linear has them (`resolvedTickets`). */
  tickets: Ticket[];
  body: string;
  additions: number;
  deletions: number;
  changedFiles: number;
  /** GitHub's decision, PolicyBot's word for it where a repo has one. Kept for app builds before `review`. */
  reviewDecision: string | null;
  /** GitHub's raw merge state, which lags a conflict. Kept for app builds before `merge`; read `merge`. */
  mergeState: string;
  /** Whether GitHub would merge it now, as a row says it (`mergeOf`). */
  merge: MergeState;
  /** The review decision, as a row says it. */
  review: ReviewState;
  mergeMethod: string | null;
  policy: Policy | null;
  reviewers: Reviewer[];
  /** Paths Jai has marked viewed on GitHub. A file changed since then is not among them. */
  viewedFiles: string[];
  labels: { name: string; color: string }[];
  checks: Check[];
  comments: { nodes: Comment[] };
  reviews: { nodes: { id: string; author: Author | null; state: string; body: string; submittedAt: string | null }[] };
  reviewThreads: { nodes: {
    id: string; isResolved: boolean; isOutdated: boolean; viewerCanResolve: boolean; viewerCanUnresolve: boolean;
    path: string; line: number | null; diffSide: string; comments: { nodes: Comment[] };
  }[] };
}

interface CommonStatus {
  author: string | null;
  checks: ChecksSummary;
  review: ReviewState;
  merge: MergeState;
  /** Jai's own latest review that counts (`jaiReview`), its state lowercased. */
  jaiReview: string | null;
  jaiReviewedAt: string | null;
}

/**
 * What a list row shows, in the vocabulary the app already has for PRs (`CodingThread.PullRequest`). Each list carries
 * what is true of it alone: a due time on the review list, a merge time on a merged row.
 */
export type RowStatus = CommonStatus & (
  /**
   * `requestedAt`: when review was last asked of Jai himself (null when only a team was asked). `reviewDueAt`: one
   * working day from when he could first see it (`reviewDueAt`); null without an SLA.
   */
  | { list: "review"; requestedAt: string | null; reviewDueAt: string | null }
  | { list: "reviewed" }
  | { list: "mine" }
  | { list: "merged"; mergedAt: string | null }
);

/** A row of `GET /prs`. */
export type OpenRowStatus = Extract<RowStatus, { list: OpenList }>;

export interface PullRequest {
  repo: RepoFullName;
  number: number;
  title: string;
  head: Sha;
  /** Changes with the diff: the head, or the branch it is compared with. A base that only moves on leaves it alone. */
  revision: Revision;
  /** Changes with the detail. A check finishing does not move `updatedAt`, so the checks' overall state is in it. */
  version: string;
  updatedAt: string;
  /** Null when it belongs on none of the lists, and then it has no status. */
  status: OpenRowStatus | null;
  detail: Detail;
  /** The ticket keys its title, branch and description name, before Linear is asked (`readPullRequests` asks). */
  ticketKeys: TicketKeys;
  /** The tickets its row shows (`rowTickets`): empty until Linear has one of its keys. */
  tickets: Ticket[];
  /** The first of `tickets`, for an app older than them; null without one. */
  ticket: Ticket | null;
  /** When review was last asked of the user, for alerts (`alerts.ts`). */
  requestedAt: string | null;
  /** What `.policy.yml`'s people decided (`peopleOf`): with it, a checks-only read (`readChecks`) keeps the review. */
  people: PeopleDecision | null;
}

/**
 * The version a detail is kept under: the PR's version and a hash of what the detail says, because GitHub does not move
 * `updatedAt` for everything, resolving a thread among them.
 */
export async function detailVersionOf(pr: Pick<PullRequest, "version" | "detail">): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(pr.detail)));
  const digest = Array.from(new Uint8Array(hash).slice(0, 8), (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${pr.version}.${digest}`;
}

interface LatestReview {
  author: { login: string; avatarUrl?: string } | null;
  state: string;
  submittedAt: string | null;
}

interface Node extends Pick<PeopleNode, "peopleComments" | "committers"> {
  id: string;
  number: number;
  title: string;
  body: string;
  url: string;
  state: string;
  isDraft: boolean;
  headRefOid: string;
  headRefName: string;
  baseRefName: string;
  updatedAt: string;
  additions: number;
  deletions: number;
  changedFiles: number;
  reviewDecision: string | null;
  mergeable: string;
  mergeStateStatus: string;
  viewerDidAuthor: boolean;
  author: (Author & { __typename: string; name?: string | null }) | null;
  repository: { nameWithOwner: string; viewerDefaultMergeMethod: string | null };
  assignees?: { nodes: { login: string; name?: string | null; avatarUrl?: string | null }[] };
  /** The last commits' messages, for a co-author trailer naming who asked a bot for the PR. */
  trailers?: { nodes: { commit: { message: string } }[] };
  reviewRequests: { nodes: { requestedReviewer: { login?: string; avatarUrl?: string; name?: string } | null }[] };
  requestEvents: { nodes: RequestEvent[] };
  files: { nodes: { path: string; viewerViewedState: string }[] } | null;
  latestReviews: { nodes: LatestReview[] };
  labels: { nodes: { name: string; color: string }[] };
  /** On its own, as search reads it: GitHub answers a different `state` when `contexts` is asked for beside it. */
  overall: { nodes: { commit: { statusCheckRollup: { state: string } | null } }[] };
  commits: { nodes: { commit: { statusCheckRollup: Rollup | null } }[] };
  comments: Detail["comments"];
  reviews: Detail["reviews"];
  reviewThreads: Detail["reviewThreads"];
}

const PAGE_SIZE = 50;
const OPEN = "is:pr is:open archived:false draft:false sort:updated-desc";
const SEARCHES = [`${OPEN} user-review-requested:@me`, `${OPEN} author:@me`];
const REVIEWED_SEARCH = `${OPEN} reviewed-by:@me`;
const SEARCH_QUERY = `query($q: String!, $n: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $n, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { number updatedAt author { __typename } repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } }
  }
}`;
const AUTHOR = "author { login ... on Actor { avatarUrl(size: 80) } }";
const COMMENT = `id ${AUTHOR} body createdAt`;
const FIELDS = `fragment Fields on PullRequest {
  id number title body state isDraft url headRefOid headRefName baseRefName updatedAt additions deletions changedFiles
  reviewDecision mergeable mergeStateStatus viewerDidAuthor
  author { __typename login avatarUrl(size: 80) ... on User { name } }
  repository { nameWithOwner viewerDefaultMergeMethod }
  assignees(first: 5) { nodes { login name avatarUrl(size: 80) } }
  trailers: commits(last: 20) { nodes { commit { message } } }
  reviewRequests(first: 20) { nodes { requestedReviewer {
    ... on User { login avatarUrl(size: 80) }
    ... on Team { name }
  } } }
  latestReviews(first: 50) { nodes { ${AUTHOR} state submittedAt } }
  requestEvents: timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 20) { nodes {
    ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } } }
  } }
  files(first: 100) { nodes { path viewerViewedState } }
  labels(first: 20) { nodes { name color } }
  overall: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
  comments(first: 100) { nodes { ${COMMENT} } }
  reviews(last: 50) { nodes { id ${AUTHOR} state body submittedAt } }
  reviewThreads(last: 100) {
    nodes {
      id isResolved isOutdated viewerCanResolve viewerCanUnresolve path line diffSide
      comments(first: 30) { nodes { ${COMMENT} } }
    }
  }
  ${PEOPLE_FIELDS}
}`;

/** A PR's checks. Inline, not in a fragment: only GitHub knows which are required, and it asks for the PR's number. */
export function contextsOf(number: number): string {
  const required = `isRequired(pullRequestNumber: ${number})`;
  return `commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
    __typename
    ... on CheckRun { name status conclusion detailsUrl startedAt ${required}
      checkSuite { workflowRun { workflow { name } } } }
    ... on StatusContext { context state description targetUrl ${required} }
  } } } } } }`;
}

/**
 * Every GitHub call. On the hosted Worker a 401 refreshes the person's token once (`renewAfterUnauthorized`) and the
 * call goes again with the new one; a self-hosted Worker's token is the operator's to replace. Each answer's rate-limit
 * headers are kept (`rate-limit.ts`): while GitHub asks a token to wait, its calls answer 429 without going, and a
 * background run (`GITHUB_RATE` set) also stops when the token's hour runs low.
 */
async function github(path: string, env: Env, accept: string, init: RequestInit = {}): Promise<Response> {
  const key = isSet(env.SIGNED_IN_USER_ID) ? `user:${env.SIGNED_IN_USER_ID}` : "self";
  const started = Date.now();
  const held = heldBackoff(key, started);
  if (held && stops(held, started, env.GITHUB_RATE !== undefined)) {
    return waitAnswer(held.until, started);
  }
  const send = async (token: string) => {
    const response = await fetch(`https://api.github.com${path}`, {
      ...init,
      headers: { ...init.headers as Record<string, string> | undefined, Accept: accept, Authorization: `Bearer ${token}`,
        "User-Agent": "pr-viewer" },
    });
    const now = Date.now();
    const reserve = gitHubReserveOf(limitsOf(env));
    if (env.GITHUB_RATE) {
      observe(env.GITHUB_RATE, response, now, reserve);
    }
    holdBackoff(key, backoffOf(response, now, reserve));
    return response;
  };
  const response = await send(env.GITHUB_TOKEN);
  if (response.status !== 401 || !isSet(env.SIGNED_IN_USER_ID)) {
    return response;
  }
  const renewed = await renewAfterUnauthorized(env);
  return renewed ? send(renewed) : response;
}

export function sendToGitHub(method: string, path: string, body: object, env: Env): Promise<Response> {
  return github(path, env, "application/vnd.github+json", { method, body: JSON.stringify(body) });
}

export function postToGitHub(path: string, body: object, env: Env): Promise<Response> {
  return sendToGitHub("POST", path, body, env);
}

/**
 * A file's text at a commit or branch; with an empty `ref`, on the default branch. With `etag`, GitHub answers 304 when
 * the file is unchanged, and a 304 costs nothing of the token's hour.
 */
export function fetchFile(repo: string, path: string, ref: string, env: Env, etag?: string): Promise<Response> {
  const encoded = path.split("/").map(encodeURIComponent).join("/");
  return github(`/repos/${repo}/contents/${encoded}${ref ? `?ref=${ref}` : ""}`, env, "application/vnd.github.raw+json",
    etag ? { headers: { "If-None-Match": etag } } : {});
}

/** With `etag`, a conditional GET: 304 when nothing changed, free of the token's hour. */
export function getFromGitHub(path: string, env: Env, etag?: string): Promise<Response> {
  return github(path, env, "application/vnd.github+json", etag ? { headers: { "If-None-Match": etag } } : {});
}

/** A PR GitHub has no answer for is a null in the data and a NOT_FOUND here. Anything else fails the whole read. */
export function postGraphql(query: string, variables: object, env: Env): Promise<Response> {
  return github("/graphql", env, "application/json", {
    method: "POST",
    body: JSON.stringify({ query, variables }),
  });
}

export async function graphql<Data>(query: string, variables: object, env: Env): Promise<Data> {
  const response = await postGraphql(query, variables, env);
  if (!response.ok) {
    throw new Error(`GitHub GraphQL answered ${response.status}`);
  }
  const body = (await response.json()) as { data?: Data; errors?: { type?: string; message?: string }[] };
  const failure = body.errors?.find((error) => error.type !== "NOT_FOUND");
  if (!body.data || failure) {
    throw new Error(`GitHub GraphQL failed: ${failure?.type ?? "no data"}`);
  }
  return body.data;
}

const DECISIONS = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"];

/**
 * Jai's review as a row reports it: a change request that still stands, else his latest. `latestReviews` won't do alone:
 * GitHub leaves out anyone asked to review again, and lists a comment over the change request it does not lift.
 */
export function jaiReview(
  node: { latestReviews: Node["latestReviews"]; reviews?: { nodes: (LatestReview & { author: Author | null })[] } },
  login: string,
): LatestReview | undefined {
  const own = (node.reviews?.nodes ?? []).filter((review) => review.author?.login === login && review.state !== "PENDING");
  const standing = own.findLast((review) => DECISIONS.includes(review.state));
  if (standing?.state === "CHANGES_REQUESTED") {
    return standing;
  }
  return node.latestReviews.nodes.find((review) => review.author?.login === login && review.state !== "PENDING")
    ?? own.at(-1);
}

/** GitHub's own state of a PR, as the phone draws it. */
export function detailState(node: { state: string; isDraft: boolean }): Detail["state"] {
  if (node.state === "MERGED") return "merged";
  if (node.state === "CLOSED") return "closed";
  return node.isDraft ? "draft" : "open";
}

/** Which of Jai's lists a PR belongs on, or null when it belongs on none. `wasAsked`: it is on his review list now. */
export function listOf(
  node: { state: string; isDraft: boolean; author: { __typename: string; login: string } | null;
    reviewRequests: Node["reviewRequests"]; latestReviews: Node["latestReviews"] },
  login: string,
  wasAsked = false,
): OpenList | null {
  if (node.state !== "OPEN" || node.isDraft || node.author?.__typename === "Bot") {
    return null;
  }
  if (node.reviewRequests.nodes.some((request) => request.requestedReviewer?.login === login)) {
    return "review";
  }
  if (node.author?.login === login) {
    return "mine";
  }
  return wasAsked && jaiReview(node, login) ? "reviewed" : null;
}

const POLICY_BOT = /^policy-b[io]t: /;
const POLICY_STATES: Record<string, PolicyState> = {
  SUCCESS: "approved", PENDING: "pending", EXPECTED: "pending", FAILURE: "disapproved",
};
const POLICY_DECISIONS: Record<PolicyState, string | null> = {
  approved: "APPROVED", pending: "REVIEW_REQUIRED", disapproved: "CHANGES_REQUESTED", unknown: null,
};

function isPolicyBot(context: Context): boolean {
  return POLICY_BOT.test(context.context ?? "");
}

/** PolicyBot's verdict on the head. It is the authority: GitHub's review decision can't see its rules. */
export function policyOf(contexts: Context[]): Policy | null {
  const status = contexts.find(isPolicyBot);
  return status
    ? { state: POLICY_STATES[status.state ?? ""] ?? "unknown", description: status.description ?? null,
      url: status.targetUrl ?? null, required: status.isRequired ?? false }
    : null;
}

/**
 * GitHub's decision where no PolicyBot answered, and PolicyBot's word for it where one did. A change request is the
 * exception: PolicyBot can pass while GitHub still holds the merge for one.
 */
export function reviewDecisionOf(
  policy: Policy | null, decision: string | null, people: PeopleDecision | null = null,
): string | null {
  if (decision === "CHANGES_REQUESTED") return decision;
  // Where `.policy.yml` could be read, its people decide; PolicyBot's word also carries its conditions (checks).
  return people ?? (policy && POLICY_DECISIONS[policy.state]) ?? decision;
}

/**
 * Each check once. GitHub lists a check again for every workflow run on the commit, one per PR event, and the latest run
 * counts. One that hasn't started is the newest. The same name in two workflows is two checks.
 */
export function latestChecks(contexts: Context[]): Context[] {
  const latest = new Map<string, Context>();
  for (const context of contexts) {
    const workflow = context.checkSuite?.workflowRun?.workflow.name ?? "";
    const key = `${workflow}\n${context.name ?? context.context ?? "check"}`;
    const seen = latest.get(key);
    if (!seen || (context.startedAt ?? "\uffff") >= (seen.startedAt ?? "\uffff")) {
      latest.set(key, context);
    }
  }
  return [...latest.values()];
}

/**
 * What a PR's checks say about merging it, which is only what its required checks say. PolicyBot is the review, not a
 * check.
 */
export function requiredChecks(contexts: Context[]): string | null {
  const required = contexts.filter((one) => one.isRequired && !isPolicyBot(one));
  const states = latestChecks(required).map((context) => checkOf(context).state);
  if (states.includes("failure")) {
    return "FAILURE";
  }
  if (states.includes("pending")) {
    return "PENDING";
  }
  return states.length > 0 ? "SUCCESS" : null;
}

export function reviewersOf(node: Pick<Node, "reviewRequests" | "latestReviews">): Reviewer[] {
  const requested = node.reviewRequests.nodes.flatMap(({ requestedReviewer: reviewer }) => {
    const login = reviewer?.login ?? reviewer?.name;
    return login ? [{ login, avatarUrl: reviewer?.avatarUrl ?? null, state: "REQUESTED" }] : [];
  });
  const waitedOn = new Set(requested.map((reviewer) => reviewer.login));
  const reviewed = node.latestReviews.nodes.flatMap(({ author, state }) => (
    author && !waitedOn.has(author.login) && state !== "PENDING"
      ? [{ login: author.login, avatarUrl: author.avatarUrl ?? null, state }] : []
  ));
  return [...reviewed, ...requested];
}

/** The two shapes GitHub reports a check in, as one. */
export function checkOf(context: Context): Check {
  const outcome = context.conclusion ?? context.state ?? null;
  const isRunning = context.__typename === "CheckRun" && context.status !== "COMPLETED";
  const state: CheckState = isRunning || outcome === "PENDING" || outcome === "EXPECTED" ? "pending"
    : outcome === "SUCCESS" ? "success"
      : ["NEUTRAL", "SKIPPED"].includes(outcome ?? "") ? "skipped"
        // Cancelled means nothing unless GitHub is waiting on it, and then the merge is held like any failure.
        : ["CANCELLED", "STALE"].includes(outcome ?? "") && !context.isRequired ? "skipped" : "failure";
  return {
    name: context.name ?? context.context ?? "check", state, url: context.detailsUrl ?? context.targetUrl ?? null,
    required: context.isRequired ?? false, workflow: context.checkSuite?.workflowRun?.workflow.name ?? null,
  };
}

const CHECKS: Record<string, ChecksSummary> = {
  SUCCESS: "passing", FAILURE: "failing", ERROR: "failing", PENDING: "pending", EXPECTED: "pending",
};
const REVIEWS: Record<string, ReviewState> = {
  APPROVED: "approved", CHANGES_REQUESTED: "changes_requested", REVIEW_REQUIRED: "required",
};
const MERGES: Record<string, MergeState> = {
  CLEAN: "clean", HAS_HOOKS: "clean", BEHIND: "behind", BLOCKED: "blocked", DRAFT: "blocked", DIRTY: "conflicting",
  UNSTABLE: "unstable",
};

/** A PR that conflicts is one whatever GitHub's merge state has got to, and it can lag. */
export function mergeOf(mergeable: string | null, mergeState: string): MergeState {
  return mergeable === "CONFLICTING" ? "conflicting" : MERGES[mergeState] ?? "unknown";
}

/** The one reading of what GitHub says of a PR's checks and review: PolicyBot's word over GitHub's, its status no check. */
export function verdictOf(
  node: { reviewDecision: string | null; overall: Node["overall"]; commits: { nodes: { commit: {
    statusCheckRollup: { contexts: { nodes: Context[] } } | null } }[] } },
  people: PeopleDecision | null = null,
): {
  checks: ChecksSummary; review: ReviewState; decision: string | null; policy: Policy | null; overall: string | null;
  contexts: Context[];
} {
  const overall = node.overall.nodes[0]?.commit.statusCheckRollup?.state ?? null;
  const contexts = node.commits.nodes[0]?.commit.statusCheckRollup?.contexts.nodes ?? [];
  const policy = policyOf(contexts);
  const decision = reviewDecisionOf(policy, node.reviewDecision, people);
  return {
    checks: CHECKS[requiredChecks(contexts) ?? ""] ?? "none",
    review: REVIEWS[decision ?? ""] ?? "none",
    decision, policy, overall, contexts,
  };
}

/** A row's status on one of the open lists; the request and due times are kept on the review list alone. */
export function rowStatus(
  list: OpenList, author: string | null, checks: ChecksSummary, review: ReviewState, merge: MergeState,
  mine?: LatestReview, reviewDueAt: string | null = null, requestedAt: string | null = null,
): OpenRowStatus {
  const common = {
    author, checks, review, merge, jaiReview: mine?.state.toLowerCase() ?? null, jaiReviewedAt: mine?.submittedAt ?? null,
  };
  return list === "review" ? { list, ...common, requestedAt, reviewDueAt } : { list, ...common };
}

export interface RequestEvent { createdAt?: string; requestedReviewer?: { login?: string } | null }

/** When review was last asked of `login`, or null when only a team was asked. */
export function reviewRequestedAt(events: RequestEvent[], login: string): string | null {
  return events.filter((event) => event.requestedReviewer?.login === login && event.createdAt)
    .map((event) => event.createdAt as string).sort().at(-1) ?? null;
}

/**
 * A review SLA's working week: hours are local, `offsetHours` from UTC all year, weekdays 0 (Sunday) to 6. Argus's SLA
 * (`ReviewSLADeadline`) is one local working day, and the day starts when the reviewer can first see the request, so one
 * sent at night or at the weekend gets the whole next working day.
 */
export interface ReviewWeek {
  offsetHours: number;
  startHour: number;
  endHour: number;
  weekdays: number[];
}

/**
 * The week from `REVIEW_SLA_UTC_OFFSET_HOURS` (`7`), `REVIEW_SLA_HOURS` (`9-18`) and `REVIEW_SLA_WEEKDAYS` (`1,2,3,4,5`).
 * Null, so no row has a due time, when any is unset or makes no sense.
 */
export function reviewWeek(env: Pick<Env, "REVIEW_SLA_UTC_OFFSET_HOURS" | "REVIEW_SLA_HOURS" | "REVIEW_SLA_WEEKDAYS">):
  ReviewWeek | null {
  const { REVIEW_SLA_UTC_OFFSET_HOURS: offset, REVIEW_SLA_HOURS: hours, REVIEW_SLA_WEEKDAYS: days } = env;
  if (!isSet(offset) || !isSet(hours) || !isSet(days)) return null;
  const offsetHours = Number(offset);
  const span = /^\s*(\d{1,2})\s*-\s*(\d{1,2})\s*$/.exec(hours);
  const weekdays = days.split(",").map((day) => Number(day.trim()));
  if (!Number.isFinite(offsetHours) || Math.abs(offsetHours) > 14 || !span) return null;
  const [startHour, endHour] = [Number(span[1]), Number(span[2])];
  const isDay = (day: number) => Number.isInteger(day) && day >= 0 && day <= 6;
  if (startHour >= endHour || endHour > 24 || weekdays.length === 0 || !weekdays.every(isDay)) return null;
  return { offsetHours, startHour, endHour, weekdays };
}

export function reviewDueAt(requestedAt: string | null, week: ReviewWeek | null): string | null {
  if (!requestedAt || !week) return null;
  const offset = week.offsetHours * 3_600_000;
  const day = 86_400_000;
  const isWorkday = (local: Date) => week.weekdays.includes(local.getUTCDay());
  let local = new Date(Date.parse(requestedAt) + offset);
  const hour = local.getUTCHours() + local.getUTCMinutes() / 60;
  if (!isWorkday(local) || hour < week.startHour || hour >= week.endHour) {
    const midnight = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate());
    let open = midnight + week.startHour * 3_600_000 + (hour >= week.startHour ? day : 0);
    while (!isWorkday(new Date(open))) open += day;
    local = new Date(open);
  }
  let due = local.getTime() + day;
  while (!isWorkday(new Date(due))) due += day;
  return new Date(due - offset).toISOString().replace(".000Z", "Z");
}

/** What a check run or a commit status can move on a PR: its checks, PolicyBot's status among them, its merge state. */
export interface ChecksNode {
  headRefOid: string;
  updatedAt: string;
  reviewDecision: string | null;
  mergeable: string;
  mergeStateStatus: string;
  overall: Node["overall"];
  commits: Node["commits"];
}

/** A PR's checks as its row and its detail say them, and the version they make (`PullRequest.version`). */
export interface ChecksRead {
  version: string;
  checks: ChecksSummary;
  review: ReviewState;
  merge: MergeState;
  detail: Pick<Detail, "reviewDecision" | "mergeState" | "merge" | "review" | "policy" | "checks">;
}

/** The one reading of a PR's checks, for a full read (`pullRequest`) and a checks-only one (`readChecks`) alike. */
export function checksRead(node: ChecksNode, people: PeopleDecision | null): ChecksRead {
  const { checks, review, decision, policy, overall, contexts } = verdictOf(node, people);
  const merge = mergeOf(node.mergeable, node.mergeStateStatus);
  return {
    version: `${node.updatedAt}.${overall ?? "NONE"}`, checks, review, merge,
    detail: {
      reviewDecision: decision, mergeState: node.mergeStateStatus, merge, review, policy,
      checks: latestChecks(contexts).filter((context) => !isPolicyBot(context)).map(checkOf),
    },
  };
}

/** A PR read from GitHub, as the index stores it and the phone shows it. Rows and the detail share one verdict. */
export function pullRequest(
  node: Node, login: string, wasAsked: boolean, week: ReviewWeek | null, people: PeopleDecision | null,
  bots: ReadonlySet<string> = new Set(),
): PullRequest {
  const { version, checks, review, merge, detail: verdict } = checksRead(node, people);
  const list = listOf(node, login, wasAsked);
  const requestedAt = reviewRequestedAt(node.requestEvents.nodes, login);
  const head = shaOf(node.headRefOid);
  const ticketKeys = ticketKeysOf(node.title, node.headRefName, node.body);
  const authorIsBot = isBotAuthor(node.author, bots);
  return {
    repo: repoOf(node.repository.nameWithOwner),
    number: node.number,
    title: node.title,
    head,
    revision: revisionOf(head, node.baseRefName),
    version,
    updatedAt: node.updatedAt,
    people,
    status: list && rowStatus(
      list, node.author?.login ?? null, checks, review, merge, jaiReview(node, login), reviewDueAt(requestedAt, week),
      requestedAt,
    ),
    requestedAt,
    ticketKeys,
    tickets: [],
    ticket: null,
    detail: {
      id: node.id, url: node.url, state: detailState(node), head: node.headRefOid, base: node.baseRefName,
      headBranch: node.headRefName,
      author: node.author, isAuthor: node.viewerDidAuthor, authorIsBot,
      requestedBy: authorIsBot ? requestedByOf(node, bots) : null, tickets: resolvedTickets(ticketKeys, new Map()),
      body: node.body, additions: node.additions,
      deletions: node.deletions, changedFiles: node.changedFiles, reviewDecision: verdict.reviewDecision,
      mergeState: verdict.mergeState, merge, review, mergeMethod: node.repository.viewerDefaultMergeMethod,
      policy: verdict.policy, reviewers: reviewersOf(node),
      viewedFiles: (node.files?.nodes ?? []).filter((file) => file.viewerViewedState === "VIEWED").map((file) => file.path),
      labels: node.labels.nodes, checks: verdict.checks,
      comments: node.comments, reviews: node.reviews, reviewThreads: node.reviewThreads,
    },
  };
}

interface SearchPage {
  search: {
    pageInfo: { hasNextPage: boolean; endCursor: string | null };
    nodes: { number: number; updatedAt: string; author: { __typename: string } | null;
      repository: { nameWithOwner: string };
      commits: { nodes: { commit: { statusCheckRollup: { state: string } | null } }[] } }[];
  };
}

async function search(q: string, env: Env): Promise<Listing[]> {
  const found: Listing[] = [];
  let after: string | null = null;
  do {
    const page: SearchPage = await graphql<SearchPage>(SEARCH_QUERY, { q, n: PAGE_SIZE, after }, env);
    for (const node of page.search.nodes) {
      if (node.author?.__typename !== "Bot") {
        const repo = repoOf(node.repository.nameWithOwner);
        const id = prId(repo, node.number);
        const rollup = node.commits.nodes[0]?.commit.statusCheckRollup?.state ?? "NONE";
        found.push({ id, repo, number: node.number, version: `${node.updatedAt}.${rollup}`, reviewedOnly: false });
      }
    }
    after = page.search.pageInfo.hasNextPage ? page.search.pageInfo.endCursor : null;
  } while (after !== null);
  return found;
}

/**
 * Every open PR on a list, by every page: a short answer would read as PRs that have gone. Jai has reviewed far more
 * than his list holds, so what only that search found counts for the rows already held.
 */
export async function searchListings(env: Env): Promise<Map<PrId, Listing>> {
  const [listed, reviewed] = await Promise.all([
    Promise.all(SEARCHES.map((q) => search(q, env))),
    search(REVIEWED_SEARCH, env),
  ]);
  const found = new Map<PrId, Listing>();
  for (const listing of reviewed) {
    found.set(listing.id, { ...listing, reviewedOnly: true });
  }
  for (const listing of listed.flat()) {
    found.set(listing.id, listing);
  }
  return found;
}

/** The PRs named, by `id`, with everything the phone shows. A PR GitHub has no answer for maps to null. */
/** Merged PRs, newest merge first: GitHub's search, read only when Jai asks for them. Jai's own, or ones he reviewed. */
export const MERGED_LIMIT = 50;
const MERGED_QUERY = `query($q: String!, $n: Int!) {
  search(query: $q, type: ISSUE, first: $n) {
    nodes { ... on PullRequest { number title headRefOid baseRefName updatedAt mergedAt additions deletions changedFiles
      author { login } repository { nameWithOwner } } }
  }
}`;

interface MergedNode {
  number: number; title: string; headRefOid: string; baseRefName: string; updatedAt: string; mergedAt: string | null;
  additions: number; deletions: number; changedFiles: number; author: { login: string } | null;
  repository: { nameWithOwner: string };
}

/** A row of `GET /prs/merged`. */
export interface MergedRow {
  repo: RepoFullName;
  number: number;
  title: string;
  head: Sha;
  revision: Revision;
  diff: "ready" | "too_large";
  detail: string;
  keyLines: null;
  status: Extract<RowStatus, { list: "merged" }>;
}

/** A merged PR as a PRs-tab row. Its diff and detail load when it opens, as for any PR named by a link. */
export function mergedRow(node: MergedNode): MergedRow {
  const tooLarge = node.changedFiles > 300 || node.additions + node.deletions > 20_000;
  const head = shaOf(node.headRefOid);
  return {
    repo: repoOf(node.repository.nameWithOwner), number: node.number, title: node.title, head,
    revision: revisionOf(head, node.baseRefName), diff: tooLarge ? "too_large" : "ready",
    detail: `${node.updatedAt}.MERGED`, keyLines: null,
    status: {
      list: "merged", author: node.author?.login ?? null, checks: "none", review: "none", merge: "unknown",
      jaiReview: null, jaiReviewedAt: null, mergedAt: node.mergedAt,
    },
  };
}

export const MERGED_SEARCHES = {
  mine: "is:pr is:merged author:@me archived:false sort:updated-desc",
  reviewed: "is:pr is:merged reviewed-by:@me -author:@me archived:false sort:updated-desc",
} as const;

export async function mergedPullRequests(
  env: Env, kind: keyof typeof MERGED_SEARCHES = "mine",
): Promise<MergedRow[]> {
  const data = await graphql<{ search: { nodes: (MergedNode | Record<string, never>)[] } }>(MERGED_QUERY,
    { q: MERGED_SEARCHES[kind], n: MERGED_LIMIT }, env);
  return data.search.nodes.filter((node): node is MergedNode => "number" in node).map(mergedRow)
    .sort((a, b) => (b.status.mergedAt ?? "").localeCompare(a.status.mergedAt ?? ""));
}

/** `lookUp` asks Linear about ticket keys: the index passes its cache (`cachedTickets`). */
export async function readPullRequests(
  refs: PullRequestRef[], env: Env, asked: ReadonlySet<string> = new Set(),
  lookUp: (keys: string[]) => Promise<Map<string, Ticket>> = (keys) => lookUpTickets(keys, env),
  cache?: GitHubCache,
): Promise<Map<PrId, PullRequest | null>> {
  const fields = refs.map((ref, index) => {
    const { owner, name } = repoParts(ref.repo);
    return `p${index}: repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(name)}) {
      pullRequest(number: ${ref.number}) { ...Fields ${contextsOf(ref.number)} } }`;
  });
  const [data, login] = await Promise.all([
    graphql<Record<string, { pullRequest: Node | null } | null>>(`query { ${fields.join("\n")} } ${FIELDS}`, {}, env),
    githubLogin(env),
  ]);
  const week = reviewWeek(env);
  const bots = botAuthorsOf(env);
  const people = await Promise.all(refs.map((ref, index) => {
    const node = data[`p${index}`]?.pullRequest;
    return node ? peopleOf(ref.repo, node, env, cache).catch(() => null) : null;
  }));
  const read = refs.map((ref, index) => {
    const node = data[`p${index}`]?.pullRequest;
    return node ? pullRequest(node, login, asked.has(ref.id), week, people[index] ?? null, bots) : null;
  });
  const keys = [...new Set(read.flatMap((pr) => pr ? allKeys(pr.ticketKeys) : []))];
  const issues = keys.length > 0 ? await lookUp(keys) : new Map<string, Ticket>();
  for (const pr of read) {
    if (pr) {
      pr.detail.tickets = resolvedTickets(pr.ticketKeys, issues);
      pr.tickets = rowTickets(pr.ticketKeys, pr.detail.tickets);
      pr.ticket = pr.tickets[0] ?? null;
    }
  }
  return new Map(refs.map((ref, index) => [ref.id, read[index] ?? null]));
}

const CHECKS_FIELDS = `headRefOid updatedAt reviewDecision mergeable mergeStateStatus
  overall: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }`;

/**
 * Only the checks of the PRs named (`ChecksNode`), all in one query: what a check suite or a status can change. GitHub
 * prices it at one point for dozens of PRs, where a full read (`readPullRequests`) costs a point per PR and the
 * `.policy.yml` and membership REST calls besides. A PR GitHub has no answer for maps to null.
 */
export async function readChecks(refs: PullRequestRef[], env: Env): Promise<Map<PrId, ChecksNode | null>> {
  const fields = refs.map((ref, index) => {
    const { owner, name } = repoParts(ref.repo);
    return `p${index}: repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(name)}) {
      pullRequest(number: ${ref.number}) { ${CHECKS_FIELDS} ${contextsOf(ref.number)} } }`;
  });
  const data = await graphql<Record<string, { pullRequest: ChecksNode | null } | null>>(
    `query { ${fields.join("\n")} }`, {}, env);
  return new Map(refs.map((ref, index) => [ref.id, data[`p${index}`]?.pullRequest ?? null]));
}

/** A picker row for any PR, open or not (`GET /prs/{owner}/{repo}/{n}/summary`). */
export interface Summary {
  repo: RepoFullName;
  number: number;
  title: string;
  state: Detail["state"];
  author: string | null;
  updatedAt: string;
  url: string;
}

const SUMMARY_QUERY = `query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    number title state isDraft updatedAt url author { login } repository { nameWithOwner }
  } }
}`;

interface SummaryNode {
  number: number; title: string; state: string; isDraft: boolean; updatedAt: string; url: string;
  author: { login: string } | null; repository: { nameWithOwner: string };
}

export function summaryOf(node: SummaryNode): Summary {
  return {
    repo: repoOf(node.repository.nameWithOwner), number: node.number, title: node.title, state: detailState(node),
    author: node.author?.login ?? null, updatedAt: node.updatedAt, url: node.url,
  };
}

/** Null when GitHub has no such PR the token can see: an unknown repo, an issue's number, or one past the last. */
export async function pullRequestSummary(repo: RepoFullName, number: number, env: Env): Promise<Summary | null> {
  const { owner, name } = repoParts(repo);
  const data = await graphql<{ repository: { pullRequest: SummaryNode | null } | null }>(
    SUMMARY_QUERY, { owner, name, number }, env);
  const node = data.repository?.pullRequest;
  return node ? summaryOf(node) : null;
}

export function fetchDiff(repo: string, number: number, env: Env): Promise<Response> {
  return github(`/repos/${repo}/pulls/${number}`, env, "application/vnd.github.v3.diff");
}

/** The revision a PR is at now, from GitHub's REST answer; null when it can't be read. */
export function revisionFrom(pull: unknown): Revision | null {
  const { head, base } = (pull ?? {}) as { head?: { sha?: unknown }; base?: { ref?: unknown } };
  const sha = parseSha(head?.sha);
  return sha && typeof base?.ref === "string" ? revisionOf(sha, base.ref) : null;
}

/**
 * A PR's diff now, and the revision it is of. GitHub's diff carries no commit, so the revision is read just after it:
 * the same revision as the one a client asked for means the head did not move away from it while the diff was read.
 */
export async function liveDiff(
  repo: string, number: number, env: Env,
): Promise<{ response: Response; version: Revision | null }> {
  const response = await fetchDiff(repo, number, env);
  if (!response.ok && response.status !== 406) {
    return { response, version: null };
  }
  const pull = await getFromGitHub(`/repos/${repo}/pulls/${number}`, env);
  const version = pull.ok ? revisionFrom(await pull.json().catch(() => null)) : null;
  return { response, version };
}
