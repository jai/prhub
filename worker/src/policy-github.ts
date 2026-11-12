import type { Env } from "./env.ts";
import { fetchFile, getFromGitHub } from "./github.ts";
import {
  type Membership, type PeopleDecision, type PeopleNode, factsOf, parsePolicy, peopleDecision,
} from "./policy-people.ts";

const POLICY_TTL_MS = 10 * 60_000;
const MEMBER_TTL_MS = 60 * 60_000;

/** One answer GitHub gave: when, its ETag, and what it said (a policy's text, or a membership). */
export interface CachedAnswer<Value> {
  at: number;
  etag: string | null;
  value: Value;
}

/**
 * Where `.policy.yml` texts and membership answers are kept between reads. The PR index keeps them in its own storage
 * (`github-cache.ts`), so they outlive the isolate and stay the person's own; anything else uses this isolate's memory.
 */
export interface GitHubCache {
  get<Value>(key: string): CachedAnswer<Value> | undefined;
  set<Value>(key: string, answer: CachedAnswer<Value>): void;
}

export function memoryCache(): GitHubCache {
  const answers = new Map<string, CachedAnswer<unknown>>();
  return {
    get: <Value>(key: string) => answers.get(key) as CachedAnswer<Value> | undefined,
    set: (key, answer) => {
      answers.set(key, answer);
    },
  };
}

const isolateCache = memoryCache();

/** The people part of a `.policy.yml` repo's review, or null where it has none or it can't be read. */
export async function peopleOf(
  repo: string, node: PeopleNode, env: Env, cache: GitHubCache = isolateCache,
): Promise<PeopleDecision | null> {
  const text = await policyText(repo, node.baseRefName, env, cache);
  const policy = text === null ? null : parsePolicy(text);
  return policy ? await peopleDecision(policy, factsOf(node), membership(env, cache)) : null;
}

/**
 * Past its TTL an answer is asked again with its ETag: GitHub's 304 says it still stands and costs nothing of the
 * token's hour, so only a change is paid for.
 */
async function policyText(repo: string, base: string, env: Env, cache: GitHubCache): Promise<string | null> {
  const key = `policy:${repo}@${base}`;
  const cached = cache.get<string | null>(key);
  if (cached && Date.now() - cached.at < POLICY_TTL_MS) return cached.value;
  const response = await fetchFile(repo, ".policy.yml", base, env, cached?.etag ?? undefined);
  if (response.status === 304 && cached) {
    cache.set(key, { ...cached, at: Date.now() });
    return cached.value;
  }
  if (!response.ok && response.status !== 404) return cached?.value ?? null;
  const text = response.ok ? await response.text() : null;
  cache.set(key, { at: Date.now(), etag: response.headers.get("etag"), value: text });
  return text;
}

function membership(env: Env, cache: GitHubCache): Membership {
  const ask = async (key: string, path: string, yes: number[]): Promise<boolean | null> => {
    const cached = cache.get<boolean>(key);
    if (cached && Date.now() - cached.at < MEMBER_TTL_MS) return cached.value;
    const response = await getFromGitHub(path, env, cached?.etag ?? undefined);
    if (response.status === 304 && cached) {
      cache.set(key, { ...cached, at: Date.now() });
      return cached.value;
    }
    const value = yes.includes(response.status) ? true : response.status === 404 ? false : null;
    if (value !== null) cache.set(key, { at: Date.now(), etag: response.headers.get("etag"), value });
    return value;
  };
  return {
    inTeam: (team, login) => {
      const [org, slug] = team.split("/");
      return org && slug
        ? ask(`team:${team}:${login}`, `/orgs/${org}/teams/${slug}/memberships/${login}`, [200])
        : Promise.resolve(false);
    },
    inOrg: (org, login) => ask(`org:${org}:${login}`, `/orgs/${org}/members/${login}`, [204]),
  };
}
