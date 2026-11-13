/**
 * Installation tokens of a GitHub App (docs/plans/github-app.md, "Tokens"): always read only, and on the hosted Worker
 * for one repo. Ask's checkout is their one use; an installation token never answers a person's own request.
 */
import { type Env, isSet, scopedKey } from "./env.ts";
import { getFromGitHub } from "./github.ts";
import { parseRepoFullName, type RepoFullName, repoParts } from "./ids.ts";

/** GitHub would not mint one: the App is not on the repo, or it refused. The message says which, for the person. */
export class InstallationTokenRefused extends Error {
  readonly status: number | null;

  constructor(message: string, status: number | null = null) {
    super(message);
    this.status = status;
  }
}

/** GitHub's words for a refusal that is its rate limit, with when it resets; null for any other refusal. */
export function rateLimitWords(response: Response): string | null {
  const remaining = response.headers.get("x-ratelimit-remaining");
  if (!(response.status === 429 || (response.status === 403 && remaining === "0"))) {
    return null;
  }
  const reset = Number(response.headers.get("x-ratelimit-reset"));
  const at = Number.isFinite(reset) && reset > 0 ? `, resets ${new Date(reset * 1000).toISOString().slice(11, 16)} UTC` : "";
  return `GitHub's rate limit for your account is used up${at}`;
}

function base64url(data: ArrayBuffer | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A GitHub App's JWT, from its id and PKCS#8 key. */
export async function appJwt(app: { id: string; key: string }, nowSeconds = Math.floor(Date.now() / 1000)): Promise<string> {
  const der = Uint8Array.from(atob(app.key.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const body = `${base64url('{"alg":"RS256","typ":"JWT"}')}.${
    base64url(JSON.stringify({ iat: nowSeconds - 30, exp: nowSeconds + 500, iss: app.id }))}`;
  return `${body}.${base64url(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(body)))}`;
}

/** Read only: what the agent may do on GitHub, whatever it is told to try. */
export const ASK_PERMISSIONS = {
  contents: "read", pull_requests: "read", issues: "read", checks: "read", actions: "read", statuses: "read",
  metadata: "read",
} as const;

function appHeaders(jwt: string): Record<string, string> {
  return { Accept: "application/vnd.github+json", Authorization: `Bearer ${jwt}`, "User-Agent": "pr-viewer" };
}

/** The id of the App's installation that holds `repo`. */
async function installationOf(repo: RepoFullName, jwt: string, fetcher: typeof fetch): Promise<number> {
  const installation = await fetcher(`https://api.github.com/repos/${repo}/installation`, { headers: appHeaders(jwt) });
  if (!installation.ok) {
    throw new InstallationTokenRefused(rateLimitWords(installation)
      ?? `The AI can't read ${repo}: the GitHub App isn't installed there.`, installation.status);
  }
  return (await installation.json() as { id: number }).id;
}

/** A read-only token of installation `id`, for `names` (repo names in its account) alone, or every repo with null. */
async function mint(
  id: number, names: string[] | null, jwt: string, repo: RepoFullName, fetcher: typeof fetch,
): Promise<string> {
  const minted = await fetcher(`https://api.github.com/app/installations/${id}/access_tokens`, {
    method: "POST", headers: appHeaders(jwt),
    body: JSON.stringify({ ...(names ? { repositories: names } : {}), permissions: ASK_PERMISSIONS }),
  });
  if (!minted.ok) {
    throw new InstallationTokenRefused(rateLimitWords(minted)
      ?? `GitHub wouldn't give the AI read access to ${repo}.`, minted.status);
  }
  return (await minted.json() as { token: string }).token;
}

/**
 * Read access for an hour, minted for the installation that holds the repo. `isNarrowed` limits it to that one repo
 * (the hosted Worker always); Jai's Ask App's reaches every repo it is installed on.
 */
export async function installationRepoToken(
  repo: RepoFullName, app: { id: string; key: string }, isNarrowed: boolean, fetcher: typeof fetch,
): Promise<string> {
  const jwt = await appJwt(app);
  const id = await installationOf(repo, jwt, fetcher);
  return mint(id, isNarrowed ? [repoParts(repo).name] : null, jwt, repo, fetcher);
}

/** The most repos one installation token can name. */
const MAX_TOKEN_REPOS = 500;
/** How long a person's list of an installation's repos is taken as current. */
export const VISIBLE_REPOS_MS = 10 * 60_000;

/**
 * The repos of installation `id` the signed-in person can see, read with their own token
 * (`GET /user/installations/{id}/repositories`) and kept under their prefix for `VISIBLE_REPOS_MS`. GitHub answers it
 * as the intersection: repos the installation covers that the person's account can read. Null when GitHub won't say.
 */
async function visibleRepos(id: number, env: Env, now: number): Promise<RepoFullName[] | null> {
  const key = scopedKey(env, `ask-reach/${id}.json`);
  const kept = await (await env.DIFFS.get(key))?.json<{ at: number; repos: RepoFullName[] }>();
  if (kept && now - kept.at < VISIBLE_REPOS_MS) {
    return kept.repos;
  }
  const repos: RepoFullName[] = [];
  for (let page = 1; page <= MAX_TOKEN_REPOS / 100; page++) {
    const response = await getFromGitHub(`/user/installations/${id}/repositories?per_page=100&page=${page}`, env);
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const { repositories } = await response.json() as { repositories?: { full_name?: string }[] };
    for (const { full_name: name } of repositories ?? []) {
      const parsed = name ? parseRepoFullName(name) : null;
      if (parsed) {
        repos.push(parsed);
      }
    }
    if ((repositories ?? []).length < 100) {
      break;
    }
  }
  await env.DIFFS.put(key, JSON.stringify({ at: now, repos }));
  return repos;
}

/** What the subscription's agent reaches on GitHub: a read-only token, and the repos it names (null: not narrowed). */
export interface AskGrant {
  token: string;
  repos: RepoFullName[] | null;
  /** How the person's sight of the PR was checked: their token, or, with it rate limited, the repos it last listed. */
  checkedBy?: "person" | "person_cached";
}

/**
 * The token for a subscription question. Hosted: the PRHub App's, read only, for every repo of the PR's installation
 * that the person's own token can see, so the agent can read a sibling repo the PR uses, and nothing the person
 * can't. The person's token stays in the Worker. Elsewhere: `askRepoToken`'s, not narrowed.
 */
export async function askGrant(
  repo: RepoFullName, number: number, env: Env, fetcher: typeof fetch = (input, init) => fetch(input, init),
  now = Date.now(),
): Promise<AskGrant> {
  if (!isSet(env.SIGNED_IN_USER_ID)) {
    return { token: await askRepoToken(repo, number, env, fetcher), repos: null };
  }
  const sight = await personSeesPr(repo, number, env);
  const jwt = await appJwt({ id: env.GITHUB_APP_ID ?? "", key: env.GITHUB_APP_PRIVATE_KEY ?? "" });
  const id = await installationOf(repo, jwt, fetcher);
  const kept = sight === "person" ? null : await keptRepos(id, env, now);
  // Rate limited: the repos the person's own token listed in the last `VISIBLE_REPOS_MS` stand in for it, and only
  // for a repo among them. Nothing else does: an installation token reaches repos the person may not see.
  if (sight !== "person" && !kept?.some((one) => one.toLowerCase() === repo.toLowerCase())) {
    throw sight;
  }
  const visible = kept ?? (await visibleRepos(id, env, now)) ?? [];
  const repos = [...new Set([repo, ...visible])].slice(0, MAX_TOKEN_REPOS);
  return {
    token: await mint(id, repos.map((one) => repoParts(one).name), jwt, repo, fetcher), repos,
    checkedBy: sight === "person" ? "person" : "person_cached",
  };
}

/** The repos of installation `id` the person's own token listed within `VISIBLE_REPOS_MS`; null when none are kept. */
async function keptRepos(id: number, env: Env, now: number): Promise<RepoFullName[] | null> {
  const kept = await (await env.DIFFS.get(scopedKey(env, `ask-reach/${id}.json`)))?.json<{ at: number; repos: RepoFullName[] }>();
  return kept && now - kept.at < VISIBLE_REPOS_MS ? kept.repos : null;
}

/**
 * "person" when their token reads the PR. Rate limited, the refusal to throw unless their own kept list stands in
 * (`askGrant`); any other refusal is thrown here.
 */
async function personSeesPr(repo: RepoFullName, number: number, env: Env): Promise<"person" | InstallationTokenRefused> {
  const visible = await getFromGitHub(`/repos/${repo}/pulls/${number}`, env);
  if (visible.ok) {
    await visible.body?.cancel();
    return "person";
  }
  await visible.body?.cancel();
  const limited = rateLimitWords(visible);
  const refusal = new InstallationTokenRefused(limited
    ?? `The AI can't read ${repo}: your GitHub account can't see this pull request.`, visible.status);
  if (limited === null) {
    throw refusal;
  }
  return refusal;
}

/**
 * The GitHub token Ask's agent gets for a PR. Hosted: the PRHub App's, for this repo alone, and only after the person's
 * own token has read the PR, since an installation token reaches repos they may not. Jai's Worker: his Ask App's.
 * Self-hosted: a PAT, `ASK_GITHUB_TOKEN` (read only), else `GITHUB_READ_TOKEN`, else `GITHUB_TOKEN`.
 */
export async function askRepoToken(
  repo: RepoFullName, number: number, env: Env, fetcher: typeof fetch = (input, init) => fetch(input, init),
): Promise<string> {
  if (isSet(env.SIGNED_IN_USER_ID)) {
    const sight = await personSeesPr(repo, number, env);
    if (sight !== "person") {
      throw sight;
    }
    return installationRepoToken(repo, { id: env.GITHUB_APP_ID ?? "", key: env.GITHUB_APP_PRIVATE_KEY ?? "" }, true,
      fetcher);
  }
  if (isSet(env.ASK_GITHUB_APP_ID) && isSet(env.ASK_GITHUB_APP_KEY)) {
    return installationRepoToken(repo, { id: env.ASK_GITHUB_APP_ID, key: env.ASK_GITHUB_APP_KEY }, false, fetcher);
  }
  if (isSet(env.ASK_GITHUB_TOKEN)) {
    return env.ASK_GITHUB_TOKEN;
  }
  return isSet(env.GITHUB_READ_TOKEN) ? env.GITHUB_READ_TOKEN : env.GITHUB_TOKEN;
}

/**
 * What the subscription's agent may reach on GitHub with the token `askRepoToken` gives. Only a token read only by how
 * it was made reaches past the checkout: an App's installation token, minted with `ASK_PERMISSIONS` (hosted: the
 * repos of the PR's installation the person can see, `installation`, from `askGrant`; Jai's Ask App: every repo it is
 * installed on, `wide`), or `ASK_GITHUB_TOKEN`, set as a read-only PAT (`wide`). `GITHUB_READ_TOKEN` and `GITHUB_TOKEN` can be classic PATs that write: with either, `none`, and the agent
 * keeps to the checkout.
 */
export function askGitHubReach(
  env: Pick<Env, "SIGNED_IN_USER_ID" | "ASK_GITHUB_APP_ID" | "ASK_GITHUB_APP_KEY" | "ASK_GITHUB_TOKEN">,
): "none" | "installation" | "wide" {
  if (isSet(env.SIGNED_IN_USER_ID)) {
    return "installation";
  }
  return (isSet(env.ASK_GITHUB_APP_ID) && isSet(env.ASK_GITHUB_APP_KEY)) || isSet(env.ASK_GITHUB_TOKEN) ? "wide" : "none";
}
