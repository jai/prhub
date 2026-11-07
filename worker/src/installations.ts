/**
 * The hosted Worker's webhook routing (docs/api.md, "Webhook routing"): which installation a delivery came from, which
 * of its members it concerns, and each person's list of installations, read with their own token.
 */
import { z } from "zod";
import type { DeliveryTarget, Member } from "./installation-core.ts";
import { parseRepoFullName, parseSha, type RepoFullName } from "./ids.ts";
import type { Fetch } from "./oauth.ts";

/** What the hosted webhook can do with one delivery. */
export type AppDelivery =
  | { kind: "installation"; installationId: string; action: string; account: string | null; repos: string[];
    senderId: number | null }
  | { kind: "installation_repositories"; installationId: string; action: string; added: string[]; removed: string[];
    senderId: number | null }
  | { kind: "target"; installationId: string; target: DeliveryTarget };

const PULL_REQUEST_EVENTS = new Set([
  "pull_request", "pull_request_review", "pull_request_review_comment", "pull_request_review_thread",
]);

const Login = z.object({ login: z.string() }).nullish();
const RepoNames = z.array(z.object({ full_name: z.string() })).nullish()
  .transform((repos) => (repos ?? []).flatMap(({ full_name: name }) => parseRepoFullName(name) ? [name] : []));
const Base = z.object({
  action: z.string().nullish(),
  installation: z.object({ id: z.number().int().positive(), account: Login }).nullish(),
  sender: z.object({ id: z.number().int().positive() }).nullish(),
  repository: z.object({ full_name: z.string() }).nullish(),
});
const PullRequestPayload = Base.extend({
  pull_request: z.object({
    number: z.number().int().positive(), user: Login, requested_reviewers: z.array(z.object({ login: z.string().nullish() }).loose()).nullish(),
  }).nullish(),
  issue: z.object({ number: z.number().int().positive(), pull_request: z.unknown(), user: Login }).nullish(),
  requested_reviewer: Login,
});
const InstallationPayload = Base.extend({ repositories: RepoNames });
const InstallationReposPayload = Base.extend({ repositories_added: RepoNames, repositories_removed: RepoNames });
const CheckSuitePayload = Base.extend({ check_suite: z.object({ head_sha: z.string() }) });
const StatusPayload = Base.extend({ sha: z.string() });

/** A delivery the hosted Worker routes, or null for one it ignores (another event, or not the shape GitHub sends). */
export function parseAppDelivery(event: string | null, payload: unknown): AppDelivery | null {
  const base = Base.safeParse(payload);
  if (!event || !base.success || !base.data.installation) {
    return null;
  }
  const installationId = String(base.data.installation.id);
  const senderId = base.data.sender?.id ?? null;
  const action = base.data.action ?? "";
  if (event === "installation") {
    const parsed = InstallationPayload.safeParse(payload);
    return parsed.success ? {
      kind: "installation", installationId, action, account: base.data.installation.account?.login ?? null,
      repos: parsed.data.repositories, senderId,
    } : null;
  }
  if (event === "installation_repositories") {
    const parsed = InstallationReposPayload.safeParse(payload);
    return parsed.success ? {
      kind: "installation_repositories", installationId, action, added: parsed.data.repositories_added,
      removed: parsed.data.repositories_removed, senderId,
    } : null;
  }
  const repo = parseRepoFullName(base.data.repository?.full_name);
  if (!repo) {
    return null;
  }
  const target = targetOf(event, repo, payload);
  return target ? { kind: "target", installationId, target } : null;
}

function targetOf(event: string, repo: RepoFullName, payload: unknown): DeliveryTarget | null {
  if (event === "check_suite" || event === "status") {
    const parsed = event === "status" ? StatusPayload.safeParse(payload) : CheckSuitePayload.safeParse(payload);
    const raw = parsed.success ? ("sha" in parsed.data ? parsed.data.sha : parsed.data.check_suite.head_sha) : null;
    const sha = parseSha(raw);
    return sha ? { kind: "head", repo, sha } : null;
  }
  if (event !== "issue_comment" && !PULL_REQUEST_EVENTS.has(event)) {
    return null;
  }
  const parsed = PullRequestPayload.safeParse(payload);
  if (!parsed.success) {
    return null;
  }
  const { pull_request: pr, issue, requested_reviewer: requested } = parsed.data;
  if (event === "issue_comment") {
    return issue?.pull_request ? { kind: "pr", repo, number: issue.number, author: issue.user?.login ?? null, reviewers: [] }
      : null;
  }
  if (!pr) {
    return null;
  }
  const reviewers = [...(pr.requested_reviewers ?? []).map((reviewer) => reviewer.login), requested?.login]
    .filter((login): login is string => typeof login === "string");
  return { kind: "pr", repo, number: pr.number, author: pr.user?.login ?? null, reviewers };
}

/** Pages read of each list; past them a person sees the rest through the poll. */
const MAX_PAGES = 20;
const HEADERS = { Accept: "application/vnd.github+json", "User-Agent": "pr-viewer", "X-GitHub-Api-Version": "2022-11-28" };

const InstallationsPage = z.object({
  installations: z.array(z.object({ id: z.number().int().positive(), account: Login }).loose()),
});
const ReposPage = z.object({ repositories: z.array(z.object({ full_name: z.string() }).loose()) });

async function pages<Item>(
  url: string, token: string, fetcher: Fetch, itemsOf: (body: unknown) => Item[] | null,
): Promise<Item[] | null> {
  const items: Item[] = [];
  for (let page = 1; page <= MAX_PAGES; page += 1) {
    let response: Response;
    try {
      response = await fetcher(`${url}${url.includes("?") ? "&" : "?"}per_page=100&page=${page}`, {
        headers: { ...HEADERS, Authorization: `Bearer ${token}` },
      });
    } catch {
      return null;
    }
    const found = response.ok ? itemsOf(await response.json().catch(() => null)) : null;
    if (!found) {
      return null;
    }
    items.push(...found);
    if (found.length < 100) {
      break;
    }
  }
  return items;
}

/**
 * The installations a person's token can reach and, in each, the repos it can see: `GET /user/installations` and
 * `GET /user/installations/{id}/repositories`. Null when GitHub could not answer all of it, so nothing is dropped on a
 * partial answer.
 */
export async function listInstallations(token: string, fetcher: Fetch):
Promise<Map<string, { account: string | null; repos: string[] }> | null> {
  const installations = await pages("https://api.github.com/user/installations", token, fetcher, (body) => {
    const parsed = InstallationsPage.safeParse(body);
    return parsed.success ? parsed.data.installations : null;
  });
  if (!installations) {
    return null;
  }
  const listed = new Map<string, { account: string | null; repos: string[] }>();
  for (const installation of installations) {
    const repos = await pages(`https://api.github.com/user/installations/${installation.id}/repositories`, token,
      fetcher, (body) => {
        const parsed = ReposPage.safeParse(body);
        return parsed.success
          ? parsed.data.repositories.flatMap(({ full_name: name }) => parseRepoFullName(name) ? [name] : []) : null;
      });
    if (!repos) {
      return null;
    }
    listed.set(String(installation.id), { account: installation.account?.login ?? null, repos });
  }
  return listed;
}

/** The parts of a person's account and of an installation that a sync needs. */
export interface SyncAccount {
  accessToken(): Promise<{ kind: "ok"; token: string; login: string; userId: string } | { kind: string }>;
  claimInstallationSync(now: number, gapMs: number): Promise<boolean> | boolean;
  installationIds(): Promise<string[]> | string[];
  setInstallations(ids: string[], now: number): Promise<void> | void;
}

export interface InstallationApi {
  join(member: Pick<Member, "user_id" | "login">, repos: string[], account: string | null, now: number): unknown;
  leave(userId: string): unknown;
  reposAdded(repos: string[], now: number): unknown;
  reposRemoved(repos: string[]): unknown;
  setSuspended(suspended: boolean): unknown;
  forget(): Promise<string[]>;
  route(target: DeliveryTarget, now: number): unknown;
}

/**
 * Reads the person's installations with their own token, joins each one with the repos they can see there, and leaves
 * the ones they no longer reach. False when it did not run: claimed too recently, signed out, or GitHub did not answer.
 */
export async function syncInstallations(
  account: SyncAccount, installation: (id: string) => InstallationApi, fetcher: Fetch, now: number, gapMs: number,
): Promise<boolean> {
  if (!(await account.claimInstallationSync(now, gapMs))) {
    return false;
  }
  const answer = await account.accessToken();
  if (answer.kind !== "ok" || !("token" in answer)) {
    return false;
  }
  const listed = await listInstallations(answer.token, fetcher);
  if (!listed) {
    return false;
  }
  const member = { user_id: answer.userId, login: answer.login };
  for (const [id, { account: owner, repos }] of listed) {
    await installation(id).join(member, repos, owner, now);
  }
  for (const id of await account.installationIds()) {
    if (!listed.has(id)) {
      await installation(id).leave(answer.userId);
    }
  }
  await account.setInstallations([...listed.keys()], now);
  return true;
}
