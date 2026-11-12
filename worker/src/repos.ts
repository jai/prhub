// The repo index for quick jump (docs/api.md, "Quick jump"): every repo the token can see, so the app
// filters by name on the phone and a PR number then opens directly.
import { type Env, githubLogin, isSet } from "./env.ts";
import { postGraphql } from "./github.ts";
import { countOf, LimitName, limitsOf } from "./limits.ts";

export const REPOS_KEY = "repos/index.json";
/** Older than this, the next request answers the copy it has and reads GitHub again behind it. */
export const REPOS_STALE_MS = 6 * 60 * 60_000;
/** `?refresh=1` reads GitHub at most this often; sooner, it answers the copy it has. */
export const REPOS_FORCED_GAP_MS = 5 * 60_000;
/** A stale copy's background read is not tried again sooner than this, so a failing GitHub is not asked every request. */
export const REPOS_RETRY_GAP_MS = 2 * 60_000;
/** How far back the relevance hint looks, and how many of the user's PRs it counts at most. */
const RECENT_DAYS = 90;
const RECENT_LIMIT = 500;
const PAGE = 100;

export interface Repo {
  nameWithOwner: string;
  name: string;
  archived: boolean;
  pushedAt: string | null;
  openPrs: number;
  /** PRs the user authored, reviewed, was asked to review, commented on or was mentioned in, updated in 90 days. */
  recentPrs: number;
  /** PRs of this repo on the user's list now (`GET /prs`). Filled in when served, from the index. */
  listed: number;
}

export interface RepoIndex {
  repos: Repo[];
  owners: string[];
  updatedAt: string;
  truncated: boolean;
}

interface RepoNode {
  nameWithOwner: string;
  name: string;
  isArchived: boolean;
  pushedAt: string | null;
  pullRequests: { totalCount: number };
}

interface Connection {
  pageInfo: { hasNextPage: boolean; endCursor: string | null };
  nodes: (RepoNode | null)[];
}

const REPO_FIELDS = "pageInfo { hasNextPage endCursor } nodes { nameWithOwner name isArchived pushedAt "
  + "pullRequests(states: OPEN) { totalCount } }";
const VIEWER_REPOS = `query($after: String) { viewer { repositories(first: ${PAGE}, after: $after,
  affiliations: [OWNER, ORGANIZATION_MEMBER], ownerAffiliations: [OWNER, ORGANIZATION_MEMBER]) { ${REPO_FIELDS} } } }`;
const OWNER_REPOS = `query($owner: String!, $after: String) { repositoryOwner(login: $owner) {
  repositories(first: ${PAGE}, after: $after) { ${REPO_FIELDS} } } }`;
const RECENT_QUERY = `query($q: String!, $after: String) { search(query: $q, type: ISSUE, first: ${PAGE}, after: $after) {
  pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { repository { nameWithOwner } } } } }`;

/**
 * GraphQL that keeps what it got: an org whose SSO the token is not authorized for comes back as an error beside the
 * rest, and costs the index only that org.
 */
async function partialGraphql<Data>(query: string, variables: object, env: Env): Promise<Data> {
  const response = await postGraphql(query, variables, env);
  if (!response.ok) {
    throw new Error(`GitHub GraphQL answered ${response.status}`);
  }
  const body = (await response.json()) as { data?: Data | null; errors?: { type?: string }[] };
  if (!body.data) {
    throw new Error(`GitHub GraphQL failed: ${body.errors?.[0]?.type ?? "no data"}`);
  }
  return body.data;
}

async function pages(read: (after: string | null) => Promise<Connection | null>, limit: number): Promise<RepoNode[]> {
  const found: RepoNode[] = [];
  let after: string | null = null;
  do {
    const page = await read(after);
    if (!page) {
      break;
    }
    found.push(...page.nodes.filter((node): node is RepoNode => node !== null));
    after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (after !== null && found.length < limit);
  return found;
}

/** `GITHUB_ORGS`, comma-separated, or none: then every repo the user owns or sees through an org. */
export function ownersOf(env: Pick<Env, "GITHUB_ORGS">): string[] {
  return isSet(env.GITHUB_ORGS) ? env.GITHUB_ORGS.split(",").map((owner) => owner.trim()).filter(Boolean) : [];
}

/**
 * The most repos the index keeps (`indexed_repos_max`): a token that sees more gets the most recently pushed this many,
 * and `truncated`.
 */
export function maxReposOf(env: Env): number {
  return countOf(limitsOf(env), LimitName.IndexedReposMax);
}

export async function fetchRepoNodes(env: Env): Promise<RepoNode[]> {
  const owners = ownersOf(env);
  // One page past the cap, so a cut is known to be one.
  const limit = maxReposOf(env) + 1;
  if (owners.length === 0) {
    return pages(async (after) => (await partialGraphql<{ viewer: { repositories: Connection } }>(
      VIEWER_REPOS, { after }, env)).viewer.repositories, limit);
  }
  const each = await Promise.all(owners.map((owner) => pages(async (after) => (await partialGraphql<{
    repositoryOwner: { repositories: Connection } | null }>(OWNER_REPOS, { owner, after }, env))
    .repositoryOwner?.repositories ?? null, limit)));
  return each.flat();
}

/** How many of the user's recent PRs each repo holds: the ranking hint. A failed search ranks by push alone. */
export async function fetchRecentCounts(env: Env, now: number): Promise<Map<string, number>> {
  const since = new Date(now - RECENT_DAYS * 86_400_000).toISOString().slice(0, 10);
  const q = `is:pr involves:${await githubLogin(env)} updated:>=${since}`;
  const counts = new Map<string, number>();
  let after: string | null = null;
  let seen = 0;
  do {
    const data: { search: { pageInfo: Connection["pageInfo"]; nodes: { repository?: { nameWithOwner: string } }[] } } =
      await partialGraphql(RECENT_QUERY, { q, after }, env);
    for (const node of data.search.nodes) {
      const repo = node.repository?.nameWithOwner;
      if (repo) {
        counts.set(repo, (counts.get(repo) ?? 0) + 1);
      }
    }
    seen += data.search.nodes.length;
    after = data.search.pageInfo.hasNextPage ? data.search.pageInfo.endCursor : null;
  } while (after !== null && seen < RECENT_LIMIT);
  return counts;
}

/** Most recently pushed first when cut; each repo once, though two owners' lists name it. */
export function buildRepoIndex(
  nodes: RepoNode[], recent: ReadonlyMap<string, number>, now: number, maxRepos: number,
): RepoIndex {
  const unique = new Map<string, RepoNode>();
  for (const node of nodes) {
    unique.set(node.nameWithOwner.toLowerCase(), node);
  }
  const sorted = [...unique.values()].sort((a, b) => (b.pushedAt ?? "").localeCompare(a.pushedAt ?? ""));
  const kept = sorted.slice(0, maxRepos);
  const repos = kept.map((node) => ({
    nameWithOwner: node.nameWithOwner, name: node.name, archived: node.isArchived, pushedAt: node.pushedAt,
    openPrs: node.pullRequests.totalCount, recentPrs: recent.get(node.nameWithOwner) ?? 0, listed: 0,
  }));
  const owners = [...new Set(repos.map((repo) => repo.nameWithOwner.split("/")[0]))].sort((a, b) => a.localeCompare(b));
  return { repos, owners, updatedAt: new Date(now).toISOString(), truncated: sorted.length > maxRepos };
}

export async function fetchRepoIndex(env: Env, now: number): Promise<RepoIndex> {
  const [nodes, recent] = await Promise.all([
    fetchRepoNodes(env),
    fetchRecentCounts(env, now).catch(() => new Map<string, number>()),
  ]);
  return buildRepoIndex(nodes, recent, now, maxReposOf(env));
}

/**
 * The order the app shows before anything is typed: repos on the user's list, then the ones they worked in lately, then
 * by last push, archived last. The app keeps this order among the repos a typed filter matches.
 */
export function rankRepos(index: RepoIndex, listed: ReadonlyMap<string, number>): RepoIndex {
  const repos = index.repos.map((repo) => ({ ...repo, listed: listed.get(repo.nameWithOwner) ?? 0 }));
  repos.sort((a, b) => Number(a.archived) - Number(b.archived) || b.listed - a.listed || b.recentPrs - a.recentPrs
    || (b.pushedAt ?? "").localeCompare(a.pushedAt ?? "") || a.nameWithOwner.localeCompare(b.nameWithOwner));
  return { ...index, repos };
}

export function isRepoIndex(value: unknown): value is RepoIndex {
  const index = value as RepoIndex | null;
  return typeof index?.updatedAt === "string" && Array.isArray(index.repos) && Array.isArray(index.owners);
}
