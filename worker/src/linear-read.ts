// Ask's reads of Linear (docs/api.md, "AI on a subscription"): the PR's own tickets, put in the agent's instructions
// before the first question, and the two tools it calls after, `linear_issue` and `linear_search`. Every read runs here,
// in the Worker, with the person's own Linear key, as one of the fixed queries below: the agent names a ticket's key or
// a search phrase and never writes GraphQL, so nothing here can create, edit or comment. The container never holds the
// key; it asks over its answer's own lines (`agent-container.ts`).
import { z } from "zod";
import { type Env, isSet } from "./env.ts";
import { askLinear } from "./tickets.ts";

/** A ticket's key as Linear writes it. */
const KEY = /^[A-Za-z][A-Za-z0-9]{0,9}-\d+$/;

/** The most of a ticket's description the agent's instructions hold, and the most a tool's answer holds. */
export const TICKET_DESCRIPTION_KEPT = 4_000;
export const TOOL_DESCRIPTION_KEPT = 12_000;
/** The PR's tickets the instructions hold in full, and the most characters they take together. */
export const TICKETS_UP_FRONT = 3;
export const TICKETS_KEPT = 8_000;
/** A ticket's newest comments a tool's answer holds, and the most of each. */
export const COMMENTS_KEPT = 30;
export const COMMENT_KEPT = 1_500;
/** The most issues one search answers with. */
export const SEARCH_RESULTS = 10;
const SEARCH_TEXT_MAX = 200;

/** What the chat says when the person has saved no Linear key. */
export const NO_LINEAR_KEY =
  "No Linear key is saved for this account, so Linear can't be read. Tell the reviewer to add their Linear key in Settings.";

const ISSUE_FIELDS = `identifier title url description priorityLabel createdAt updatedAt dueDate
  state { name type }
  assignee { name } delegate { name } creator { name }
  labels(first: 20) { nodes { name } }
  parent { identifier title }
  children(first: 20) { nodes { identifier title state { name } } }
  project { name }
  attachments(first: 20) { nodes { title url sourceType } }`;

const COMMENT_FIELDS = `comments(first: ${COMMENTS_KEPT}) { nodes { body createdAt user { name } botActor { name } } }`;

/** The only documents this file sends: each a `query`. */
const ISSUE_QUERY = `query PRHubAskIssue($id: String!) { issue(id: $id) { ${ISSUE_FIELDS} } }`;
const ISSUE_WITH_COMMENTS_QUERY = `query PRHubAskIssueComments($id: String!) { issue(id: $id) { ${ISSUE_FIELDS} ${COMMENT_FIELDS} } }`;
const SEARCH_QUERY = `query PRHubAskSearch($term: String!) { searchIssues(term: $term, first: ${SEARCH_RESULTS}) {
  nodes { identifier title url state { name } assignee { name } } } }`;

interface Named {
  name?: string | null;
}

interface LinearComment {
  body?: string | null;
  createdAt?: string | null;
  user?: Named | null;
  botActor?: Named | null;
}

export interface LinearIssue {
  identifier: string;
  title: string;
  url?: string | null;
  description?: string | null;
  priorityLabel?: string | null;
  createdAt?: string | null;
  updatedAt?: string | null;
  dueDate?: string | null;
  state?: { name?: string | null; type?: string | null } | null;
  assignee?: Named | null;
  delegate?: Named | null;
  creator?: Named | null;
  labels?: { nodes?: Named[] | null } | null;
  parent?: { identifier: string; title: string } | null;
  children?: {
    nodes?: { identifier: string; title: string; state?: Named | null }[] | null;
  } | null;
  project?: Named | null;
  attachments?: {
    nodes?: { title?: string | null; url?: string | null; sourceType?: string | null }[] | null;
  } | null;
  comments?: { nodes?: LinearComment[] | null } | null;
}

const day = (stamp: string | null | undefined) => (stamp ? stamp.slice(0, 10) : null);

function cutAt(text: string, most: number): string {
  return text.length > most ? `${text.slice(0, most)}\n[cut at ${most} characters]` : text;
}

/** A pull request among a ticket's attachments: GitHub's own, or any link to a pull. */
function isPull(one: { url?: string | null; sourceType?: string | null }): boolean {
  return /github/i.test(one.sourceType ?? "") || /\/pull\/\d+/.test(one.url ?? "");
}

/**
 * One ticket as the agent reads it: who owns it, where it stands, what it is tied to, its description up to
 * `descriptionKept` characters, and its comments when they were asked for. Plain lines; a field Linear left empty is
 * left out.
 */
export function ticketText(issue: LinearIssue, descriptionKept: number): string {
  const lines = [`${issue.identifier}: ${issue.title}`];
  if (issue.url) {
    lines.push(`Link: ${issue.url}`);
  }
  const state = issue.state?.name
    ? `State: ${issue.state.name}${issue.state.type ? ` (${issue.state.type})` : ""}`
    : null;
  const standing = [
    state,
    issue.priorityLabel ? `Priority: ${issue.priorityLabel}` : null,
    issue.project?.name ? `Project: ${issue.project.name}` : null,
    issue.dueDate ? `Due: ${issue.dueDate}` : null,
  ].filter(Boolean);
  if (standing.length > 0) {
    lines.push(standing.join(" · "));
  }
  const people = [
    `Owner (assignee): ${issue.assignee?.name ?? "nobody"}`,
    issue.delegate?.name ? `Delegated to the agent: ${issue.delegate.name}` : null,
    issue.creator?.name ? `Created by: ${issue.creator.name}` : null,
  ].filter(Boolean);
  lines.push(people.join(" · "));
  const dates = [
    day(issue.createdAt) ? `Created: ${day(issue.createdAt)}` : null,
    day(issue.updatedAt) ? `Updated: ${day(issue.updatedAt)}` : null,
  ].filter(Boolean);
  if (dates.length > 0) {
    lines.push(dates.join(" · "));
  }
  const labels = (issue.labels?.nodes ?? []).flatMap((one) => (one.name ? [one.name] : []));
  if (labels.length > 0) {
    lines.push(`Labels: ${labels.join(", ")}`);
  }
  if (issue.parent) {
    lines.push(`Parent: ${issue.parent.identifier} ${issue.parent.title}`);
  }
  const children = issue.children?.nodes ?? [];
  if (children.length > 0) {
    lines.push(
      "Sub-issues:",
      ...children.map(
        (one) => `- ${one.identifier} ${one.title}${one.state?.name ? ` (${one.state.name})` : ""}`,
      ),
    );
  }
  const attachments = (issue.attachments?.nodes ?? []).filter((one) => one.url);
  const pulls = attachments.filter(isPull);
  const links = attachments.filter((one) => !isPull(one));
  const linked = (one: { title?: string | null; url?: string | null }) =>
    `- ${one.url}${one.title ? ` (${one.title})` : ""}`;
  if (pulls.length > 0) {
    lines.push("Linked pull requests:", ...pulls.map(linked));
  }
  if (links.length > 0) {
    lines.push("Other links:", ...links.map(linked));
  }
  const description = (issue.description ?? "").trim();
  lines.push("Description:", description ? cutAt(description, descriptionKept) : "(none)");
  if (issue.comments) {
    const comments = issue.comments.nodes ?? [];
    lines.push(
      comments.length > 0
        ? `Comments (the newest ${comments.length}, newest first):`
        : "Comments: none.",
      ...comments.map(
        (one) =>
          `- ${day(one.createdAt) ?? "?"} ${one.user?.name ?? one.botActor?.name ?? "someone"}: ${cutAt((one.body ?? "").trim(), COMMENT_KEPT)}`,
      ),
    );
  }
  return lines.join("\n");
}

/** The agent's instructions about Linear: the PR's own tickets, whether the read tools work, and what to say if not. */
export interface AskTickets {
  /** Whether the person has a Linear key: the read tools work only then. */
  connected: boolean;
  /** The keys the PR's title, branch and description name. */
  named: string[];
  /** The tickets Linear has for them, as text, in the PR's order: the first `TICKETS_UP_FRONT`, within `TICKETS_KEPT`. */
  tickets: { key: string; text: string }[];
  /** Keys Linear has a ticket for that did not fit: the agent reads them with `linear_issue`. */
  more: string[];
  /** Linear did not answer: the tickets are unknown, not absent. */
  unavailable: boolean;
}

/**
 * The PR's own tickets, read in one call with the person's key. A key Linear has no ticket for (a branch's `fix-12`) is
 * simply not there; no answer at all is `unavailable`, never "no ticket".
 */
export async function askTickets(
  keys: string[],
  env: Pick<Env, "LINEAR_API_KEY">,
): Promise<AskTickets> {
  const named = [...new Set(keys.filter((key) => KEY.test(key)).map((key) => key.toUpperCase()))];
  const none = { named, tickets: [], more: [], unavailable: false };
  if (!isSet(env.LINEAR_API_KEY)) {
    return { ...none, connected: false };
  }
  if (named.length === 0) {
    return { ...none, connected: true };
  }
  const asked = named.slice(0, TICKETS_UP_FRONT);
  const answer = await askLinear<Record<string, LinearIssue | null>>(
    `query PRHubAskTickets { ${asked
      .map((key, index) => `t${index}: issue(id: ${JSON.stringify(key)}) { ${ISSUE_FIELDS} }`)
      .join("\n")} }`,
    {},
    env,
  );
  if (!answer?.data) {
    return { ...none, connected: true, unavailable: true };
  }
  const tickets: { key: string; text: string }[] = [];
  const more: string[] = named.slice(TICKETS_UP_FRONT);
  let size = 0;
  asked.forEach((_key, index) => {
    const issue = answer.data?.[`t${index}`];
    if (!issue || tickets.some((one) => one.key === issue.identifier)) {
      return;
    }
    const text = scrubKey(ticketText(issue, TICKET_DESCRIPTION_KEPT), env);
    if (size + text.length > TICKETS_KEPT && tickets.length > 0) {
      more.unshift(issue.identifier);
      return;
    }
    tickets.push({ key: issue.identifier, text });
    size += text.length;
  });
  return { connected: true, named, tickets, more, unavailable: false };
}

/** A tool's answer, as the container hands it to the agent. */
export interface LinearRead {
  text: string;
  isError: boolean;
}

const READ = z.discriminatedUnion("tool", [
  z.strictObject({
    tool: z.literal("issue"),
    key: z.string().regex(KEY),
    comments: z.boolean().optional(),
  }),
  z.strictObject({
    tool: z.literal("search"),
    text: z.string().trim().min(1).max(SEARCH_TEXT_MAX),
  }),
]);

const REFUSED =
  'Linear is read only from this chat: {"tool":"issue","key":"ENG-12","comments":true} reads one ticket, {"tool":"search","text":"…"} finds tickets. Nothing else is offered.';

/** The key out of anything said back: Linear never echoes it, and this makes sure. */
function scrubKey(text: string, env: Pick<Env, "LINEAR_API_KEY">): string {
  return isSet(env.LINEAR_API_KEY) ? text.split(env.LINEAR_API_KEY).join("[redacted]") : text;
}

/**
 * One read the agent asked for. Anything but the two shapes above is refused before Linear is asked; the two run a
 * fixed query, the agent's words going in as a variable.
 */
export async function readLinear(
  input: unknown,
  env: Pick<Env, "LINEAR_API_KEY">,
): Promise<LinearRead> {
  const asked = READ.safeParse(input);
  if (!asked.success) {
    return { text: REFUSED, isError: true };
  }
  if (!isSet(env.LINEAR_API_KEY)) {
    return { text: NO_LINEAR_KEY, isError: true };
  }
  const read = asked.data;
  if (read.tool === "issue") {
    const key = read.key.toUpperCase();
    const answer = await askLinear<{ issue?: LinearIssue | null }>(
      read.comments ? ISSUE_WITH_COMMENTS_QUERY : ISSUE_QUERY,
      { id: key },
      env,
    );
    if (!answer) {
      return { text: "Linear did not answer. Say so; don't guess the ticket.", isError: true };
    }
    const issue = answer.data?.issue;
    return issue
      ? { text: scrubKey(ticketText(issue, TOOL_DESCRIPTION_KEPT), env), isError: false }
      : { text: `Linear has no ticket ${key} that this person's key can read.`, isError: true };
  }
  const answer = await askLinear<{
    searchIssues?: {
      nodes?: {
        identifier: string;
        title: string;
        url?: string | null;
        state?: Named | null;
        assignee?: Named | null;
      }[];
    } | null;
  }>(SEARCH_QUERY, { term: read.text }, env);
  const found = answer?.data?.searchIssues?.nodes;
  if (!found) {
    return { text: "Linear did not answer the search. Say so.", isError: true };
  }
  return {
    text: scrubKey(
      found.length > 0
        ? found
            .map(
              (one) =>
                `${one.identifier}: ${one.title} (${one.state?.name ?? "?"}, owner ${one.assignee?.name ?? "nobody"})${one.url ? ` ${one.url}` : ""}`,
            )
            .join("\n")
        : "No ticket matches.",
      env,
    ),
    isError: false,
  };
}
