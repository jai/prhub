import { type Env, githubLogin } from "./env.ts";
import { contextsOf, detailState, jaiReview, mergeOf, postGraphql, verdictOf } from "./github.ts";
import { peopleOf } from "./policy-github.ts";
import { PEOPLE_FIELDS, type PeopleDecision, type PeopleNode } from "./policy-people.ts";

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
  overall: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
  ${PEOPLE_FIELDS}
}`;

type StateNode = Parameters<typeof verdictOf>[0] & Parameters<typeof jaiReview>[0] & PeopleNode & {
  title: string; state: string; isDraft: boolean; mergeable: string; mergeStateStatus: string; createdAt: string;
  author: { login: string; name?: string | null } | null;
  viewerLatestReview: { state: string; submittedAt: string | null } | null;
  viewerLatestReviewRequest: { id: string } | null;
};

export interface PrState {
  title: string;
  state: string;
  checks: string;
  merge: string | null;
  review: string;
  author: string | null;
  author_name: string | null;
  created_at: string;
  jai_review: string | null;
  jai_reviewed_at: string | null;
  jai_review_requested: boolean;
}

/** A PR's state in the words Agent Pager keeps. An unsent draft review shows only here: the PRs tab asks for none. */
export function stateOf(node: StateNode, login: string, people: PeopleDecision | null = null): PrState {
  const state = detailState(node);
  const { checks, review } = verdictOf(node, people);
  const mine = jaiReview(node, login);
  const draft = node.viewerLatestReview?.state === "PENDING" ? node.viewerLatestReview : undefined;
  const author = node.author?.login ?? "";
  const name = node.author?.name?.trim() ?? "";
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
    jai_review_requested: node.viewerLatestReviewRequest !== null,
  };
}

/** `refs` as the route takes them, or null if that is not what was sent. */
export function parseRefs(body: unknown): string[] | null {
  const refs = (body as { refs?: unknown } | null)?.refs;
  return Array.isArray(refs) && refs.length > 0 && refs.length <= MAX_REFS
    && refs.every((ref) => typeof ref === "string" && REF.test(ref)) ? refs as string[] : null;
}

export function statesQuery(refs: string[]): { query: string; aliases: Map<string, [string, string]> } {
  const byRepo = new Map<string, string[]>();
  for (const ref of refs) {
    const [repo] = ref.split("#");
    byRepo.set(repo, [...byRepo.get(repo) ?? [], ref]);
  }
  const aliases = new Map<string, [string, string]>();
  const parts = [...byRepo].map(([repo, named], index) => {
    const [owner, name] = repo.split("/");
    const fields = named.map((ref, at) => {
      aliases.set(ref, [`r${index}`, `p${at}`]);
      const number = Number(ref.split("#")[1]);
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
  answer: GraphqlAnswer, aliases: Map<string, [string, string]>, login: string,
  people: ReadonlyMap<string, PeopleDecision | null> = new Map(),
): StatesAnswer {
  const missing = new Set((answer.errors ?? []).filter((error) => error.type === "NOT_FOUND")
    .map((error) => (error.path ?? []).slice(0, 2).join(".")));
  const result: StatesAnswer = { states: {}, unanswered: [] };
  for (const [ref, [repo, pull]] of aliases) {
    const node = answer.data?.[repo]?.[pull];
    if (node) {
      result.states[ref] = stateOf(node, login, people.get(ref) ?? null);
    } else if (missing.has(repo) || missing.has(`${repo}.${pull}`)) {
      result.states[ref] = null;
    } else {
      result.unanswered.push(ref);
    }
  }
  return result;
}

export class GitHubFailure extends Error {}

async function ask(refs: string[], env: Env): Promise<StatesAnswer | "refused"> {
  const { query, aliases } = statesQuery(refs);
  const response = await postGraphql(query, {}, env);
  if (!response.ok) {
    throw new GitHubFailure(`HTTP ${response.status}`);
  }
  const answer = (await response.json()) as GraphqlAnswer;
  if (answer.data) {
    const people = new Map(await Promise.all([...aliases].map(async ([ref, [repo, pull]]) => {
      const node = answer.data?.[repo]?.[pull];
      const decision = node ? await peopleOf(ref.split("#")[0] ?? "", node, env).catch(() => null) : null;
      return [ref, decision] as const;
    })));
    return statesFrom(answer, aliases, await githubLogin(env), people);
  }
  if (answer.errors?.some((error) => error.type === "RATE_LIMITED")) {
    throw new GitHubFailure("HTTP 200 RATE_LIMITED");
  }
  return "refused";
}

/** One PR can spoil a whole query, so a query GitHub refused outright is asked again one PR at a time, once. */
export async function readStates(refs: string[], env: Env): Promise<StatesAnswer> {
  const answer = await ask(refs, env);
  if (answer !== "refused") {
    return answer;
  }
  const result: StatesAnswer = { states: {}, unanswered: [] };
  for (const ref of refs) {
    const alone = await ask([ref], env);
    if (alone === "refused") {
      result.unanswered.push(ref);
    } else {
      Object.assign(result.states, alone.states);
      result.unanswered.push(...alone.unanswered);
    }
  }
  return result;
}

export async function statesRoute(request: Request, env: Env): Promise<Response> {
  const refs = parseRefs(await request.json().catch(() => null));
  if (!refs) {
    return new Response("bad request\n", { status: 400 });
  }
  try {
    return Response.json(await readStates(refs, env));
  } catch (failure) {
    if (failure instanceof GitHubFailure) {
      return Response.json({ reason: failure.message }, { status: 502 });
    }
    throw failure;
  }
}
