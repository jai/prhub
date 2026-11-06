import { type Env, githubLogin, isSet } from "./env.ts";

/** `reviewed`: GitHub dropped the request when Jai answered it. The PR stays where it was until it closes. */
export type ListKind = "review" | "reviewed" | "mine" | "merged";

/** What a search says about a PR: enough to tell whether the index is behind. */
export interface Listing {
  id: string;
  repo: string;
  number: number;
  version: string;
  /** Found only by the search for what Jai reviewed. */
  reviewedOnly: boolean;
}

export interface PullRequestRef {
  id: string;
  repo: string;
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

export type CheckState = "success" | "failure" | "pending" | "skipped";

export interface Check {
  name: string;
  state: CheckState;
  url: string | null;
  /** GitHub holds the merge for this check. */
  required: boolean;
}

/** PolicyBot's status on the head, in its own words. The reasons stay on the page `url` opens. */
export interface Policy {
  state: "approved" | "pending" | "disapproved" | "unknown";
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
  state: "open" | "draft" | "merged" | "closed";
  head: string;
  base: string;
  headBranch: string;
  author: Author | null;
  isAuthor: boolean;
  body: string;
  additions: number;
  deletions: number;
  changedFiles: number;
  reviewDecision: string | null;
  mergeState: string;
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

/** What a list row shows, in the vocabulary the app already has for PRs (`CodingThread.PullRequest`). */
export interface RowStatus {
  list: ListKind | null;
  author: string | null;
  checks: string;
  review: string;
  merge: string;
  jaiReview: string | null;
  jaiReviewedAt: string | null;
  /** When Jai's review is due: one working day from when he could first see the request (`reviewDueAt`). */
  reviewDueAt: string | null;
}

export interface PullRequest {
  repo: string;
  number: number;
  title: string;
  head: string;
  /** Changes with the diff: the head, or the branch it is compared with. A base that only moves on leaves it alone. */
  revision: string;
  /** Changes with the detail. A check finishing does not move `updatedAt`, so the checks' overall state is in it. */
  version: string;
  updatedAt: string;
  list: ListKind | null;
  status: RowStatus;
  detail: Detail;
}

interface LatestReview {
  author: { login: string; avatarUrl?: string } | null;
  state: string;
  submittedAt: string | null;
}

interface Node {
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
  author: (Author & { __typename: string }) | null;
  repository: { nameWithOwner: string; viewerDefaultMergeMethod: string | null };
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
  author { __typename login avatarUrl(size: 80) }
  repository { nameWithOwner viewerDefaultMergeMethod }
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

function github(path: string, env: Env, accept: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`https://api.github.com${path}`, {
    ...init,
    headers: { Accept: accept, Authorization: `Bearer ${env.GITHUB_TOKEN}`, "User-Agent": "pr-viewer" },
  });
}

export function sendToGitHub(method: string, path: string, body: object, env: Env): Promise<Response> {
  return github(path, env, "application/vnd.github+json", { method, body: JSON.stringify(body) });
}

export function postToGitHub(path: string, body: object, env: Env): Promise<Response> {
  return sendToGitHub("POST", path, body, env);
}

/** A file's text at a commit or branch; with an empty `ref`, on the default branch. */
export function fetchFile(repo: string, path: string, ref: string, env: Env): Promise<Response> {
  const encoded = path.split("/").map(encodeURIComponent).join("/");
  return github(`/repos/${repo}/contents/${encoded}${ref ? `?ref=${ref}` : ""}`, env, "application/vnd.github.raw+json");
}

export function getFromGitHub(path: string, env: Env): Promise<Response> {
  return github(path, env, "application/vnd.github+json");
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
): ListKind | null {
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

export function revisionOf(head: string, baseBranch: string): string {
  return `${head}-${baseBranch.replace(/[^\w.-]/g, "_")}`;
}

const POLICY_BOT = /^policy-b[io]t: /;
const POLICY_STATES: Record<string, Policy["state"]> = {
  SUCCESS: "approved", PENDING: "pending", EXPECTED: "pending", FAILURE: "disapproved",
};
const POLICY_DECISIONS: Record<Policy["state"], string | null> = {
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
export function reviewDecisionOf(policy: Policy | null, decision: string | null): string | null {
  return decision === "CHANGES_REQUESTED" ? decision : (policy && POLICY_DECISIONS[policy.state]) ?? decision;
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
    required: context.isRequired ?? false,
  };
}

const CHECKS: Record<string, string> = {
  SUCCESS: "passing", FAILURE: "failing", ERROR: "failing", PENDING: "pending", EXPECTED: "pending",
};
const REVIEWS: Record<string, string> = {
  APPROVED: "approved", CHANGES_REQUESTED: "changes_requested", REVIEW_REQUIRED: "required",
};
const MERGES: Record<string, string> = {
  CLEAN: "clean", HAS_HOOKS: "clean", BEHIND: "behind", BLOCKED: "blocked", DRAFT: "blocked", DIRTY: "conflicting",
  UNSTABLE: "unstable",
};

/** A PR that conflicts is one whatever GitHub's merge state has got to, and it can lag. */
export function mergeOf(mergeable: string | null, mergeState: string): string {
  return mergeable === "CONFLICTING" ? "conflicting" : MERGES[mergeState] ?? "unknown";
}

/** The one reading of what GitHub says of a PR's checks and review: PolicyBot's word over GitHub's, its status no check. */
export function verdictOf(
  node: { reviewDecision: string | null; overall: Node["overall"]; commits: { nodes: { commit: {
    statusCheckRollup: { contexts: { nodes: Context[] } } | null } }[] } },
): { checks: string; review: string; policy: Policy | null; overall: string | null; contexts: Context[] } {
  const overall = node.overall.nodes[0]?.commit.statusCheckRollup?.state ?? null;
  const contexts = node.commits.nodes[0]?.commit.statusCheckRollup?.contexts.nodes ?? [];
  const policy = policyOf(contexts);
  return {
    checks: CHECKS[requiredChecks(contexts) ?? ""] ?? "none",
    review: REVIEWS[reviewDecisionOf(policy, node.reviewDecision) ?? ""] ?? "none",
    policy, overall, contexts,
  };
}

export function rowStatus(
  list: ListKind | null, author: string | null, checks: string, review: string, merge: string,
  mine?: LatestReview, reviewDueAt: string | null = null,
): RowStatus {
  return {
    list, author, checks, review, merge, jaiReview: mine?.state.toLowerCase() ?? null,
    jaiReviewedAt: mine?.submittedAt ?? null, reviewDueAt: list === "review" ? reviewDueAt : null,
  };
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

function pullRequest(node: Node, login: string, wasAsked: boolean, week: ReviewWeek | null): PullRequest {
  const { checks, review, policy, overall, contexts } = verdictOf(node);
  const list = listOf(node, login, wasAsked);
  return {
    repo: node.repository.nameWithOwner,
    number: node.number,
    title: node.title,
    head: node.headRefOid,
    revision: revisionOf(node.headRefOid, node.baseRefName),
    version: `${node.updatedAt}.${overall ?? "NONE"}`,
    updatedAt: node.updatedAt,
    list,
    status: rowStatus(
      list, node.author?.login ?? null, checks, review, mergeOf(node.mergeable, node.mergeStateStatus),
      jaiReview(node, login), reviewDueAt(reviewRequestedAt(node.requestEvents.nodes, login), week),
    ),
    detail: {
      id: node.id, url: node.url, state: detailState(node), head: node.headRefOid, base: node.baseRefName,
      headBranch: node.headRefName,
      author: node.author, isAuthor: node.viewerDidAuthor, body: node.body, additions: node.additions,
      deletions: node.deletions, changedFiles: node.changedFiles, reviewDecision: node.reviewDecision,
      mergeState: node.mergeStateStatus, mergeMethod: node.repository.viewerDefaultMergeMethod, policy,
      reviewers: reviewersOf(node),
      viewedFiles: (node.files?.nodes ?? []).filter((file) => file.viewerViewedState === "VIEWED").map((file) => file.path),
      labels: node.labels.nodes, checks: latestChecks(contexts).filter((context) => !isPolicyBot(context)).map(checkOf),
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
        const repo = node.repository.nameWithOwner;
        const id = `${repo}#${node.number}`;
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
export async function searchListings(env: Env): Promise<Map<string, Listing>> {
  const [listed, reviewed] = await Promise.all([
    Promise.all(SEARCHES.map((q) => search(q, env))),
    search(REVIEWED_SEARCH, env),
  ]);
  const found = new Map<string, Listing>();
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

/** A merged PR as a PRs-tab row. Its diff and detail load when it opens, as for any PR named by a link. */
export function mergedRow(node: MergedNode) {
  const tooLarge = node.changedFiles > 300 || node.additions + node.deletions > 20_000;
  return {
    repo: node.repository.nameWithOwner, number: node.number, title: node.title, head: node.headRefOid,
    revision: revisionOf(node.headRefOid, node.baseRefName), diff: tooLarge ? "too_large" : "ready",
    detail: `${node.updatedAt}.MERGED`, keyLines: null,
    status: { ...rowStatus("merged", node.author?.login ?? null, "none", "none", "unknown"), mergedAt: node.mergedAt },
  };
}

export const MERGED_SEARCHES = {
  mine: "is:pr is:merged author:@me archived:false sort:updated-desc",
  reviewed: "is:pr is:merged reviewed-by:@me -author:@me archived:false sort:updated-desc",
} as const;

export async function mergedPullRequests(
  env: Env, kind: keyof typeof MERGED_SEARCHES = "mine",
): Promise<ReturnType<typeof mergedRow>[]> {
  const data = await graphql<{ search: { nodes: (MergedNode | Record<string, never>)[] } }>(MERGED_QUERY,
    { q: MERGED_SEARCHES[kind], n: MERGED_LIMIT }, env);
  return data.search.nodes.filter((node): node is MergedNode => "number" in node).map(mergedRow)
    .sort((a, b) => (b.status.mergedAt ?? "").localeCompare(a.status.mergedAt ?? ""));
}

export async function readPullRequests(
  refs: PullRequestRef[], env: Env, asked: ReadonlySet<string> = new Set(),
): Promise<Map<string, PullRequest | null>> {
  const fields = refs.map((ref, index) => {
    const [owner, name] = ref.repo.split("/");
    return `p${index}: repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(name)}) {
      pullRequest(number: ${ref.number}) { ...Fields ${contextsOf(ref.number)} } }`;
  });
  const [data, login] = await Promise.all([
    graphql<Record<string, { pullRequest: Node | null } | null>>(`query { ${fields.join("\n")} } ${FIELDS}`, {}, env),
    githubLogin(env),
  ]);
  const week = reviewWeek(env);
  return new Map(refs.map((ref, index) => {
    const node = data[`p${index}`]?.pullRequest;
    return [ref.id, node ? pullRequest(node, login, asked.has(ref.id), week) : null];
  }));
}

export function fetchDiff(repo: string, number: number, env: Env): Promise<Response> {
  return github(`/repos/${repo}/pulls/${number}`, env, "application/vnd.github.v3.diff");
}
