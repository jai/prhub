import type { Env } from "./env.ts";

/** Who asked a bot for its PR, and where the Worker read it. A login where one is known; a name where only that is. */
export interface RequestedBy {
  login: string | null;
  name: string | null;
  avatarUrl: string | null;
  source: "co_author" | "body" | "assignee";
}

interface Person {
  login: string;
  name?: string | null;
  avatarUrl?: string | null;
}

/** What `requestedByOf` reads of a PR. */
export interface RequesterNode {
  body: string;
  author: { __typename?: string; login: string } | null;
  assignees?: { nodes: Person[] };
  trailers?: { nodes: { commit: { message: string } }[] };
}

/** `BOT_AUTHORS`, lowercased: accounts GitHub calls users that open PRs for someone else. */
export function botAuthorsOf(env: Pick<Env, "BOT_AUTHORS">): Set<string> {
  return new Set((env.BOT_AUTHORS ?? "").split(",").map((login) => login.trim().toLowerCase()).filter(Boolean));
}

/** A GitHub App's account, a `[bot]` login, or one `BOT_AUTHORS` names. */
export function isBotAuthor(author: RequesterNode["author"], bots: ReadonlySet<string>): boolean {
  if (!author) {
    return false;
  }
  const login = author.login.toLowerCase();
  return author.__typename === "Bot" || login.endsWith("[bot]") || bots.has(login);
}

const CO_AUTHOR = /^co-authored-by:\s*(.+?)\s*<([^>]+)>\s*$/gim;
/** Coding agents sign their commits too; they asked for nothing. */
const AGENT_NAME = /\b(claude|codex|copilot|cursor|devin|gemini|openai|anthropic)\b/i;
const AGENT_EMAIL = /@(anthropic\.com|openai\.com|cursor\.com|github\.com)$|\[bot\]@/i;
const NOREPLY = /^(?:\d+\+)?([A-Za-z0-9-]+)@users\.noreply\.github\.com$/i;
const REQUESTED_BY = /^[\s>*_-]*requested by[*_\s]*:?[*_\s]*(.+)$/im;
const MENTION = /@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/;

/**
 * The human behind a bot's PR, first found: a co-author trailer on its commits that is no coding agent, a "Requested
 * by" line in its description, else its first assignee that is no bot. Null when none is recorded.
 */
export function requestedByOf(node: RequesterNode, bots: ReadonlySet<string>): RequestedBy | null {
  return coAuthor(node, bots) ?? requestedInBody(node.body) ?? assignee(node, bots);
}

function coAuthor(node: RequesterNode, bots: ReadonlySet<string>): RequestedBy | null {
  for (const { commit } of [...(node.trailers?.nodes ?? [])].reverse()) {
    for (const [, name, email] of commit.message.matchAll(CO_AUTHOR)) {
      const login = NOREPLY.exec(email)?.[1] ?? null;
      if (AGENT_NAME.test(name) || AGENT_EMAIL.test(email) || (login && bots.has(login.toLowerCase()))) {
        continue;
      }
      return { login, name, avatarUrl: login ? avatarOf(login) : null, source: "co_author" };
    }
  }
  return null;
}

function requestedInBody(body: string): RequestedBy | null {
  const said = REQUESTED_BY.exec(body)?.[1]?.trim();
  if (!said) {
    return null;
  }
  const login = MENTION.exec(said)?.[1] ?? null;
  if (login) {
    return { login, name: null, avatarUrl: avatarOf(login), source: "body" };
  }
  // A name, its Markdown and any link dropped: "**Art Doe**", "[Art Doe](https://…)".
  const name = said.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/[*_`]/g, "").trim().slice(0, 80);
  return name ? { login: null, name, avatarUrl: null, source: "body" } : null;
}

function assignee(node: RequesterNode, bots: ReadonlySet<string>): RequestedBy | null {
  const person = node.assignees?.nodes.find((candidate) => !isBotAuthor(candidate, bots));
  return person
    ? { login: person.login, name: person.name ?? null, avatarUrl: person.avatarUrl ?? avatarOf(person.login),
      source: "assignee" }
    : null;
}

function avatarOf(login: string): string {
  return `https://github.com/${login}.png?size=80`;
}
