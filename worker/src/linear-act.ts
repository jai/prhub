// Ask's comments on a PR's Linear tickets (docs/api.md, "Commenting on Linear"). The agent proposes one with
// `linear_act`; it shows under the answer as a card, with each @mention as the Linear user it reaches; and only the
// person's confirmation posts it, here, with their own Linear key. The container never holds the key.
import type { Env } from "./env.ts";
import { scopedKey } from "./env.ts";
import type { RepoFullName } from "./ids.ts";
import type { Fetch } from "./oauth.ts";
import { askLinear, type LinearAnswer } from "./tickets.ts";

/** The most comments one answer proposes. */
export const LINEAR_ACTS = 3;

/** A mention as written (`@Octbot`) and the Linear user it reaches; `user` is null when none or several are that close. */
export interface LinearMention {
  written: string;
  /** `agent`: an app user, such as Octobot. Linear starts an agent session when a comment mentions one. */
  user: { name: string; display_name: string; agent: boolean } | null;
}

/**
 * A comment the agent proposed. `text` is what the card shows: the words as they post, each mention as the user's name.
 * `post` is what Linear gets: each mention as the user's profile URL, which Linear turns into the mention itself.
 * `problem` says why it can't post (a mention that reaches nobody, an issue the PR doesn't name, no Linear connection).
 */
export interface LinearProposal {
  issue: string;
  text: string;
  post: string;
  mentions: LinearMention[];
  problem: string | null;
}

/** Where a proposal stands, kept apart from the chat: a turn that ends later writes the chat it began with. */
export interface LinearPosted {
  state: "posted" | "failed";
  url: string | null;
  problem: string | null;
  at: number;
  /** The agent session the comment's mention started, as Linear last said. */
  session?: LinearSession | null;
  /** When Linear was last asked about the session. */
  checkedAt?: number;
}

/** An agent session Linear started for a mention: the agent, where it stands, and its page in Linear. */
export interface LinearSession {
  id: string;
  agent: string | null;
  status: string;
  url: string | null;
}

/** Statuses a session leaves no more: the card stops asking Linear about it. */
export const SESSION_ENDED = new Set(["complete", "error", "stale"]);

const ISSUE = /^[A-Z][A-Z0-9]{0,9}-\d+$/;
/** `@name` after a space, a bracket or the start, so an email address mentions nobody. */
const MENTION = /(^|[\s(\[])@([A-Za-z0-9][\w-]*(?:\.[\w-]+)*)/g;

interface LinearUser {
  name: string;
  displayName: string;
  url: string;
  app?: boolean;
}

interface UsersPage {
  users: { nodes: (LinearUser & { active: boolean })[]; pageInfo: { hasNextPage: boolean; endCursor: string | null } };
}

const flat = (words: string) => words.toLowerCase().replace(/[^a-z0-9]/g, "");

/** Edits from one to the other, stopping past `most`. */
function distance(a: string, b: string, most: number): number {
  if (Math.abs(a.length - b.length) > most) {
    return most + 1;
  }
  let row = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i++) {
    const next = [i];
    for (let j = 1; j <= b.length; j++) {
      next[j] = Math.min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    row = next;
  }
  return row[b.length];
}

/**
 * The one user a written name means: the users whose display name or name it is (case, spaces and dots aside), else the
 * ones a single letter away. Null when none, or more than one, is that close: the card then says the name reached nobody.
 */
export function userFor(written: string, users: readonly LinearUser[]): LinearUser | null {
  const name = flat(written);
  const names = (user: LinearUser) => [flat(user.displayName), flat(user.name)].filter(Boolean);
  const exact = users.filter((user) => names(user).includes(name));
  if (exact.length > 0) {
    return exact.length === 1 ? exact[0] : null;
  }
  if (name.length < 4) {
    return null;
  }
  const near = users.filter((user) => names(user).some((one) => distance(name, one, 1) <= 1));
  return near.length === 1 ? near[0] : null;
}

/** Every active user of the key's workspace, people and agents alike, or null when Linear does not answer. */
export async function linearUsers(env: Pick<Env, "LINEAR_API_KEY">): Promise<LinearUser[] | null> {
  const users: LinearUser[] = [];
  let after: string | null = null;
  for (let page = 0; page < 4; page++) {
    const answer: LinearAnswer<UsersPage> | null = await askLinear<UsersPage>(
      `query PRHubUsers($after: String) { users(first: 250, after: $after) {
        nodes { name displayName url active app } pageInfo { hasNextPage endCursor } } }`, { after }, env);
    if (!answer?.data?.users) {
      return page === 0 ? null : users;
    }
    users.push(...answer.data.users.nodes.filter((user) => user.active));
    if (!answer.data.users.pageInfo.hasNextPage) {
      break;
    }
    after = answer.data.users.pageInfo.endCursor;
  }
  return users;
}

/** The comments the container handed back, as cards: each issue one the PR names, each mention made Linear's own. */
export async function proposalsOf(
  raw: unknown, tickets: () => Promise<string[]>, env: Pick<Env, "LINEAR_API_KEY">,
): Promise<LinearProposal[]> {
  const asked = (Array.isArray(raw) ? raw : []).slice(0, LINEAR_ACTS).flatMap((one) => {
    const { issue, body } = (one ?? {}) as { issue?: unknown; body?: unknown };
    const key = typeof issue === "string" ? issue.trim().toUpperCase() : "";
    return ISSUE.test(key) && typeof body === "string" && body.trim() ? [{ issue: key, body: body.slice(0, 10_000) }] : [];
  });
  if (asked.length === 0) {
    return [];
  }
  const named: string[] = await tickets().catch(() => []);
  const users = env.LINEAR_API_KEY ? await linearUsers(env) : null;
  return asked.map(({ issue, body }) => {
    const written = [...new Set([...body.matchAll(MENTION)].map((match) => match[2]))];
    const found = new Map(written.map((name) => [name, users ? userFor(name, users) : null]));
    const swap = (as: (user: LinearUser) => string) => body.replace(MENTION, (whole, before: string, name: string) => {
      const user = found.get(name);
      return user ? `${before}${as(user)}` : whole;
    });
    const mentions = written.map((name): LinearMention => {
      const user = found.get(name);
      return { written: name, user: user ? { name: user.name, display_name: user.displayName, agent: user.app === true } : null };
    });
    const lost = mentions.filter((one) => one.user === null).map((one) => `@${one.written}`);
    const problem = !env.LINEAR_API_KEY ? "Connect Linear in Settings to post this."
      : !named.includes(issue) ? `${issue} isn't one of this PR's tickets.`
      : users === null ? "Linear couldn't be reached to find who to mention. Ask again."
      : lost.length > 0 ? `No one in Linear matches ${lost.join(", ")}.`
      : null;
    // A profile URL followed by a space is how Linear's API makes a mention.
    return { issue, text: swap((user) => `@${user.name}`), post: swap((user) => user.url), mentions, problem };
  });
}

/** Linear refused because the key may not write: the words Settings and the card use. */
export const READ_ONLY_WORDS = "Your Linear key can only read. Connect one with Write or Create comments permission in Settings.";

const SCOPE = /scope|permission|forbidden|not allowed|unauthori[sz]ed|read.?only/i;

/** Whether a GraphQL error says the key may not write. */
function isScopeError(error: { message?: string; extensions?: Record<string, unknown> }): boolean {
  const code = String(error.extensions?.code ?? "");
  return /FORBIDDEN|UNAUTHORI[SZ]ED/i.test(code) || error.extensions?.statusCode === 403
    || SCOPE.test(`${error.message ?? ""} ${String(error.extensions?.userPresentableMessage ?? "")}`);
}

const SESSION_FIELDS = "agentSession { id status url appUser { name } }";

interface SessionNode {
  id: string;
  status: string;
  url: string | null;
  appUser: { name: string } | null;
}

const sessionOf = (node: SessionNode | null | undefined): LinearSession | null =>
  node ? { id: node.id, agent: node.appUser?.name ?? null, status: node.status, url: node.url } : null;

/**
 * Posts the proposal as the key's owner: the comment's URL and, when it mentions an agent, the session Linear started
 * for it; or Linear's reason it was refused. Linear may start the session a moment after the comment, so it is asked
 * again, briefly.
 */
export async function postToLinear(
  proposal: LinearProposal, env: Pick<Env, "LINEAR_API_KEY">,
  wait: (ms: number) => Promise<void> = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
): Promise<{ url: string; session: LinearSession | null } | { problem: string; readOnly: boolean }> {
  if (!env.LINEAR_API_KEY) {
    return { problem: "Connect Linear in Settings to post this.", readOnly: false };
  }
  const answer = await askLinear<{ commentCreate: { success: boolean;
    comment: { id: string; url: string; agentSession: SessionNode | null } | null } | null }>(
    `mutation PRHubComment($issue: String!, $body: String!) {
      commentCreate(input: { issueId: $issue, body: $body }) { success comment { id url ${SESSION_FIELDS} } } }`,
    { issue: proposal.issue, body: proposal.post }, env);
  if (!answer) {
    return { problem: "Linear couldn't be reached. Try again.", readOnly: false };
  }
  const comment = answer.data?.commentCreate?.comment;
  if (answer.data?.commentCreate?.success && comment?.url) {
    let session = sessionOf(comment.agentSession);
    const tagsAgent = proposal.mentions.some((one) => one.user?.agent);
    for (let tries = 0; !session && tagsAgent && tries < 3; tries++) {
      await wait(1_000);
      const again = await askLinear<{ comment: { agentSession: SessionNode | null } | null }>(
        `query PRHubCommentSession($id: String!) { comment(id: $id) { ${SESSION_FIELDS} } }`, { id: comment.id }, env);
      session = sessionOf(again?.data?.comment?.agentSession);
    }
    return { url: comment.url, session };
  }
  const error = (answer.errors?.[0] ?? {}) as { message?: string; extensions?: Record<string, unknown> };
  if (isScopeError(error)) {
    return { problem: READ_ONLY_WORDS, readOnly: true };
  }
  const said = error.extensions?.userPresentableMessage ?? error.message;
  return { problem: typeof said === "string" && said ? `Linear refused: ${said}` : "Linear refused the comment.", readOnly: false };
}

/** A session's status now, or null when Linear doesn't say. */
export async function sessionNow(id: string, env: Pick<Env, "LINEAR_API_KEY">): Promise<LinearSession | null> {
  const answer = await askLinear<{ agentSession: SessionNode | null }>(
    `query PRHubSession($id: String!) { agentSession(id: $id) { id status url appUser { name } } }`, { id }, env);
  return sessionOf(answer?.data?.agentSession);
}

/**
 * Whether a key may write comments, without writing one: a comment on an issue that can't exist. A key that may write
 * gets "not found"; one that may only read is refused for its scope. Null when the answer says neither.
 */
export async function canComment(env: Pick<Env, "LINEAR_API_KEY">, send: Fetch = fetch): Promise<boolean | null> {
  if (!env.LINEAR_API_KEY) {
    return null;
  }
  let error: { message?: string; extensions?: Record<string, unknown> } | undefined;
  try {
    const response = await send("https://api.linear.app/graphql", {
      method: "POST", headers: { Authorization: env.LINEAR_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ query: `mutation PRHubCanComment {
        commentCreate(input: { issueId: "${NO_ISSUE}", body: "." }) { success } }` }),
      signal: AbortSignal.timeout(10_000),
    });
    if (response.status === 403) {
      return false;
    }
    error = ((await response.json()) as LinearAnswer<unknown>).errors?.[0] as typeof error;
  } catch {
    return null;
  }
  if (!error) {
    return null;
  }
  if (isScopeError(error)) {
    return false;
  }
  return /not found/i.test(`${error.message ?? ""} ${String(error.extensions?.userPresentableMessage ?? "")}`) ? true : null;
}

/** An issue id no issue has: the probe's comment can't land anywhere. */
const NO_ISSUE = "00000000-0000-4000-8000-000000000000";

/** Where a PR's posted comments are kept, beside its chat. */
export function linearPostedKey(repo: RepoFullName, number: number, env: Pick<Env, "SIGNED_IN_USER_ID">): string {
  return scopedKey(env, `ask-linear/${repo}/${number}.json`);
}

/** One proposal's name in that record: its answer, then its place under it. */
export const proposalRef = (message: string, index: number) => `${message}:${index}`;
