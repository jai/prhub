import type { Env } from "./env.ts";
import { fetchFile, getFromGitHub } from "./github.ts";
import {
  type Membership, type PeopleDecision, type PeopleNode, factsOf, parsePolicy, peopleDecision,
} from "./policy-people.ts";

const POLICY_TTL_MS = 10 * 60_000;
const MEMBER_TTL_MS = 60 * 60_000;
const policies = new Map<string, { at: number; text: string | null }>();
const memberships = new Map<string, { at: number; value: boolean | null }>();

/** The people part of a `.policy.yml` repo's review, or null where it has none or it can't be read. */
export async function peopleOf(repo: string, node: PeopleNode, env: Env): Promise<PeopleDecision | null> {
  const text = await policyText(repo, node.baseRefName, env);
  const policy = text === null ? null : parsePolicy(text);
  return policy ? await peopleDecision(policy, factsOf(node), membership(env)) : null;
}

async function policyText(repo: string, base: string, env: Env): Promise<string | null> {
  const key = `${repo}@${base}`;
  const cached = policies.get(key);
  if (cached && Date.now() - cached.at < POLICY_TTL_MS) return cached.text;
  const response = await fetchFile(repo, ".policy.yml", base, env);
  if (!response.ok && response.status !== 404) return cached?.text ?? null;
  const text = response.ok ? await response.text() : null;
  policies.set(key, { at: Date.now(), text });
  return text;
}

function membership(env: Env): Membership {
  const ask = async (key: string, path: string, yes: number[]): Promise<boolean | null> => {
    const cached = memberships.get(key);
    if (cached && Date.now() - cached.at < MEMBER_TTL_MS) return cached.value;
    const response = await getFromGitHub(path, env);
    const value = yes.includes(response.status) ? true : response.status === 404 ? false : null;
    if (value !== null) memberships.set(key, { at: Date.now(), value });
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
