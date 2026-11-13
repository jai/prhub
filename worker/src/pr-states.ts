import { type Env, githubLogin } from "./env.ts";
import {
  contextsOf, detailState, jaiReview, mergeOf, postGraphql, type RequestEvent, reviewDueAt, reviewRequestedAt,
  type ReviewWeek, verdictOf,
} from "./github.ts";
import { type GitHubCache, peopleOf } from "./policy-github.ts";
import { parseRepoFullName, prId, type PrId, type RepoFullName, repoParts } from "./ids.ts";
import { PEOPLE_FIELDS, type PeopleDecision, type PeopleNode } from "./policy-people.ts";
import type { ChecksSummary, MergeState, PullRequestState, ReviewState } from "./vocab.ts";

/**
 * What a PR's state is, for PRs on none of Jai's lists too: this Worker is the one reader of it, so a list, a thread
 * and the PRs tab can't disagree. The threads hub asks here on its own schedule and sends the answers to Agent Pager.
 */
export const MAX_REFS = 20;
const REF = /^([\w.-]+)\/([\w.-]+)#(\d+)$/;
const AUTHOR_LOGIN_MAX = 39;
const AUTHOR_NAME_MAX = 100;
const FRAGMENT = `fragment State on PullRequest {
  title state isDraft mergeable mergeStateStatus reviewDecision createdAt
  author { login ... on User { name } }
  latestReviews(first: 50) { nodes { author { login } state submittedAt } }
  reviews(last: 50) { nodes { author { login } state submittedAt } }
  viewerLatestReview { state submittedAt }
  viewerLatestReviewRequest { id }
  requestEvents: timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 20) { nodes {
    ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } } }
  } }
  overall: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
  ${PEOPLE_FIELDS}
}`;

type StateNode = Parameters<typeof verdictOf>[0] & Parameters<typeof jaiReview>[0] & PeopleNode & {
  title: string; state: string; isDraft: boolean; mergeable: string; mergeStateStatus: string; createdAt: string;
  author: { login: string; name?: string | null } | null;
  viewerLatestReview: { state: string; submittedAt: string | null } | null;
  viewerLatestReviewRequest: { id: string } | null;
  requestEvents: { nodes: RequestEvent[] };
};

export interface PrState {
  title: string;
  state: PullRequestState;
  checks: ChecksSummary;
  merge: MergeState | null;
  review: ReviewState;
  author: string | null;
  author_name: string | null;
  created_at: string;
  jai_review: string | null;
  jai_reviewed_at: string | null;
  jai_review_requested: boolean;
  /** When Jai's review is due by the SLA, as a PRs-tab row's `reviewDueAt`: only while review is asked of him. */
  review_due_at: string | null;
}

/** A PR's state in the words Agent Pager keeps. An unsent draft review shows only here: the PRs tab asks for none. */
export function stateOf(
  node: StateNode, login: string, week: ReviewWeek | null = null, people: PeopleDecision | null = null,
): PrState {
  const state = detailState(node);
  const { checks, review } = verdictOf(node, people);
  const mine = jaiReview(node, login);
  const draft = node.viewerLatestReview?.state === "PENDING" ? node.viewerLatestReview : undefined;
  const author = node.author?.login ?? "";
  const name = node.author?.name?.trim() ?? "";
  const requested = node.viewerLatestReviewRequest !== null;
  return {
    title: node.title,
    state,
    checks,
    merge: state === "open" || state === "draft" ? mergeOf(node.mergeable, node.mergeStateStatus) : null,
    review,
    author: author.length > 0 && author.length <= AUTHOR_LOGIN_MAX ? author : null,
    author_name: name.length > 0 && name.length <= AUTHOR_NAME_MAX ? name : null,
    created_at: node.createdAt,
    jai_review: (mine ?? draft)?.state.toLowerCase() ?? null,
    jai_reviewed_at: (mine ?? draft)?.submittedAt ?? null,
    jai_review_requested: requested,
    review_due_at: requested ? reviewDueAt(reviewRequestedAt(node.requestEvents.nodes, login), week) : null,
  };
}

/** A ref as the route takes it, `owner/name#number`, in its parts; null when it is not one. */
export function parseRef(ref: unknown): { id: PrId; repo: RepoFullName; number: number } | null {
  const match = typeof ref === "string" ? REF.exec(ref) : null;
  const repo = match && parseRepoFullName(`${match[1]}/${match[2]}`);
  const number = Number(match?.[3]);
  return repo && Number.isSafeInteger(number) && number > 0 && prId(repo, number) === ref
    ? { id: prId(repo, number), repo, number } : null;
}

/** `refs` as the route takes them, or null if that is not what was sent. */
export function parseRefs(body: unknown): PrId[] | null {
  const refs = (body as { refs?: unknown } | null)?.refs;
  if (!Array.isArray(refs) || refs.length === 0 || refs.length > MAX_REFS) {
    return null;
  }
  const parsed = refs.map(parseRef);
  return parsed.every((ref) => ref !== null) ? parsed.map((ref) => ref.id) : null;
}

export function statesQuery(refs: PrId[]): { query: string; aliases: Map<PrId, [string, string]> } {
  const byRepo = new Map<RepoFullName, { id: PrId; number: number }[]>();
  for (const ref of refs.map(parseRef)) {
    if (ref) {
      byRepo.set(ref.repo, [...byRepo.get(ref.repo) ?? [], ref]);
    }
  }
  const aliases = new Map<PrId, [string, string]>();
  const parts = [...byRepo].map(([repo, named], index) => {
    const { owner, name } = repoParts(repo);
    const fields = named.map(({ id, number }, at) => {
      aliases.set(id, [`r${index}`, `p${at}`]);
      return `p${at}: pullRequest(number: ${number}) { ...State ${contextsOf(number)} }`;
    });
    return `r${index}: repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(name)}) { ${fields.join(" ")} }`;
  });
  return { query: `query { ${parts.join(" ")} } ${FRAGMENT}`, aliases };
}

export interface GraphqlAnswer {
  data?: Record<string, Record<string, StateNode | null> | null> | null;
  errors?: { type?: string; path?: string[] }[];
}

export interface StatesAnswer {
  /** A PR's state; null when GitHub has no such PR. */
  states: Record<string, PrState | null>;
  /** Refs GitHub answered with an error of their own, such as no access: nothing is known of them. */
  unanswered: string[];
}

/** What one query's answer says of each ref. */
export function statesFrom(
  answer: GraphqlAnswer, aliases: Map<PrId, [string, string]>, login: string, week: ReviewWeek | null = null,
  people: ReadonlyMap<string, PeopleDecision | null> = new Map(),
): StatesAnswer {
  const missing = new Set((answer.errors ?? []).filter((error) => error.type === "NOT_FOUND")
    .map((error) => (error.path ?? []).slice(0, 2).join(".")));
  const result: StatesAnswer = { states: {}, unanswered: [] };
  for (const [ref, [repo, pull]] of aliases) {
    const node = answer.data?.[repo]?.[pull];
    if (node) {
      result.states[ref] = stateOf(node, login, week, people.get(ref) ?? null);
    } else if (missing.has(repo) || missing.has(`${repo}.${pull}`)) {
      result.states[ref] = null;
    } else {
      result.unanswered.push(ref);
    }
  }
  return result;
}

/** GitHub refused or cut a states read. `code` is stable, for counting: `github_rate_limited`, `github_unavailable`, `github_failed`. */
export class GitHubFailure extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

/** The failure's code from GitHub's answer: its rate limit, its own trouble (5xx), or any other refusal. */
function failureOf(response: Response): GitHubFailure {
  const limited = response.status === 429 || (response.status === 403 && response.headers.get("x-ratelimit-remaining") === "0");
  const code = limited ? "github_rate_limited" : response.status >= 500 ? "github_unavailable" : "github_failed";
  return new GitHubFailure(code, `GitHub GraphQL answered ${response.status}`);
}

async function ask(refs: PrId[], week: ReviewWeek | null, env: Env, cache?: GitHubCache): Promise<StatesAnswer | "refused"> {
  const { query, aliases } = statesQuery(refs);
  const response = await postGraphql(query, {}, env);
  if (!response.ok) {
    await response.body?.cancel();
    throw failureOf(response);
  }
  let answer: GraphqlAnswer;
  try {
    answer = (await response.json()) as GraphqlAnswer;
  } catch (error) {
    // A big answer can arrive cut off (JSON ending mid-string near 218 KB): asked again one PR at a time, like a refusal.
    console.warn("states answer unreadable", { prs: refs.length, error: String(error) });
    return "refused";
  }
  if (answer.data) {
    const people = new Map(await Promise.all([...aliases].map(async ([ref, [repo, pull]]) => {
      const node = answer.data?.[repo]?.[pull];
      const decision = node ? await peopleOf(parseRef(ref)?.repo ?? "", node, env, cache).catch(() => null) : null;
      return [ref, decision] as const;
    })));
    return statesFrom(answer, aliases, await githubLogin(env), week, people);
  }
  if (answer.errors?.some((error) => error.type === "RATE_LIMITED")) {
    throw new GitHubFailure("github_rate_limited", "GitHub GraphQL answered 200 RATE_LIMITED");
  }
  return "refused";
}

/**
 * One PR can spoil a whole query, so a query GitHub refused outright is asked again one PR at a time, once. `cache`
 * keeps `.policy.yml` texts and memberships (`policy-github.ts`): the PR index's own, so a repeat is a hit or a free 304.
 */
export async function readStates(
  refs: PrId[], week: ReviewWeek | null, env: Env, cache?: GitHubCache,
): Promise<StatesAnswer> {
  const answer = await ask(refs, week, env, cache);
  if (answer !== "refused") {
    return answer;
  }
  const result: StatesAnswer = { states: {}, unanswered: [] };
  for (const ref of refs) {
    const alone = await ask([ref], week, env, cache);
    if (alone === "refused") {
      result.unanswered.push(ref);
    } else {
      Object.assign(result.states, alone.states);
      result.unanswered.push(...alone.unanswered);
    }
  }
  return result;
}

/** What the PR index answers for `POST /prs/states`: the states, or GitHub's refusal; and the GitHub calls it made (304s and GraphQL included). */
export type StatesResult = ({ answer: StatesAnswer } | { failure: { code: string; message: string } }) & {
  githubCalls: number;
};

/**
 * `week` is the review SLA's (`reviewWeek`), so a state's due time is the one the PRs tab's row has. The PR index reads
 * them (`PrIndex.states`), with its own cache of `.policy.yml` and memberships. `Server-Timing` says the GitHub calls it made.
 */
export async function statesRoute(
  request: Request, week: ReviewWeek | null, read: (refs: PrId[], week: ReviewWeek | null) => Promise<StatesResult>,
): Promise<Response> {
  const refs = parseRefs(await request.json().catch(() => null));
  if (!refs) {
    return new Response("bad request\n", { status: 400 });
  }
  const result = await read(refs, week);
  const headers = { "Server-Timing": `github;desc="github calls";dur=${result.githubCalls}` };
  console.log("states_read", { prs: refs.length, github_calls: result.githubCalls,
    code: "failure" in result ? result.failure.code : null });
  // Agent Pager's envelope, `{error: {code, message}}`, so a caller counts failures by code; `reason` as before.
  return "answer" in result ? Response.json(result.answer, { headers })
    : Response.json({ error: result.failure, reason: result.failure.message }, { status: 502, headers });
}
