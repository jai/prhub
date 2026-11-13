/**
 * Installation tokens of a GitHub App (docs/plans/github-app.md, "Tokens"): always read only, and on the hosted Worker
 * for one repo. Ask's checkout is their one use; an installation token never answers a person's own request.
 */
import { type Env, isSet } from "./env.ts";
import { getFromGitHub } from "./github.ts";
import { type RepoFullName, repoParts } from "./ids.ts";

/** GitHub would not mint one: the App is not on the repo, or it refused. The message says which, for the person. */
export class InstallationTokenRefused extends Error {}

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

/**
 * Read access for an hour, minted for the installation that holds the repo. `isNarrowed` limits it to that one repo
 * (the hosted Worker always); Jai's Ask App's reaches every repo it is installed on.
 */
export async function installationRepoToken(
  repo: RepoFullName, app: { id: string; key: string }, isNarrowed: boolean, fetcher: typeof fetch,
): Promise<string> {
  const headers = {
    Accept: "application/vnd.github+json", Authorization: `Bearer ${await appJwt(app)}`, "User-Agent": "pr-viewer",
  };
  const installation = await fetcher(`https://api.github.com/repos/${repo}/installation`, { headers });
  if (!installation.ok) {
    throw new InstallationTokenRefused(`The AI can't read ${repo}: the GitHub App isn't installed there.`);
  }
  const { id } = await installation.json() as { id: number };
  const minted = await fetcher(`https://api.github.com/app/installations/${id}/access_tokens`, {
    method: "POST", headers,
    body: JSON.stringify({
      ...(isNarrowed ? { repositories: [repoParts(repo).name] } : {}),
      permissions: ASK_PERMISSIONS,
    }),
  });
  if (!minted.ok) {
    throw new InstallationTokenRefused(`GitHub wouldn't give the AI read access to ${repo} (${minted.status}).`);
  }
  return (await minted.json() as { token: string }).token;
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
    const visible = await getFromGitHub(`/repos/${repo}/pulls/${number}`, env);
    if (!visible.ok) {
      throw new InstallationTokenRefused(`The AI can't read ${repo}: your GitHub account can't see this pull request.`);
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
 * it was made reaches past the checkout: an App's installation token, minted with `ASK_PERMISSIONS` (hosted: this repo
 * alone, `repo`; Jai's Ask App: every repo it is installed on, `wide`), or `ASK_GITHUB_TOKEN`, set as a read-only PAT
 * (`wide`). `GITHUB_READ_TOKEN` and `GITHUB_TOKEN` can be classic PATs that write: with either, `none`, and the agent
 * keeps to the checkout.
 */
export function askGitHubReach(
  env: Pick<Env, "SIGNED_IN_USER_ID" | "ASK_GITHUB_APP_ID" | "ASK_GITHUB_APP_KEY" | "ASK_GITHUB_TOKEN">,
): "none" | "repo" | "wide" {
  if (isSet(env.SIGNED_IN_USER_ID)) {
    return "repo";
  }
  return (isSet(env.ASK_GITHUB_APP_ID) && isSet(env.ASK_GITHUB_APP_KEY)) || isSet(env.ASK_GITHUB_TOKEN) ? "wide" : "none";
}
