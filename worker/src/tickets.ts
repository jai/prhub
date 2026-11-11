import { type Env, isSet } from "./env.ts";

const LINEAR = "https://api.linear.app/graphql";

/**
 * A Linear issue a PR names, in the shape of a list's ticket (`PRListTicket` in PRKit). `found` is null when the Worker
 * could not ask Linear (no `LINEAR_API_KEY`, or Linear did not answer), false when Linear has no such issue.
 */
export interface Ticket {
  key: string;
  url: string | null;
  title: string | null;
  state: string | null;
  state_type: string | null;
  state_color: string | null;
  found: boolean | null;
}

/** Each bracket in a title, `[ENG-1686]` or `[ENG-1686, CORE-12]`, and the keys inside it. */
const BRACKET = /\[([^\]]*)\]/g;
const KEY = /\b([A-Z][A-Z0-9]{1,9}-\d+)\b/g;
/** A key at the start of a branch or of one of its parts: `eng-1686-retry`, `alex/core-12`. Linear's team keys are short. */
const BRANCH_KEY = /(?:^|\/)([A-Za-z][A-Za-z0-9]{1,4}-\d+)(?=[-_/.]|$)/g;
/** A key or a Linear issue's URL, as a description names it. */
const BODY_REF = String.raw`(?:https://linear\.app/[\w-]+/issue/)?[A-Za-z][A-Za-z0-9]{1,9}-\d+\b`;
/**
 * Linear's magic words in a description, then the keys they name: `Fixes ENG-1`, `Part of ENG-1, ENG-2`, `Closes
 * https://linear.app/acme/issue/ENG-1/retry`. Linear links a PR to each.
 */
const MAGIC = new RegExp(String.raw`\b(?:clos(?:e[sd]?|ing)|fix(?:e[sd]|ing)?|resolv(?:e[sd]?|ing)|`
  + String.raw`complet(?:e[sd]?|ing)|refs?|references|part of|relate[sd] to|contributes to|towards?)\s*:?\s+`
  + String.raw`(${BODY_REF}(?:\s*(?:,|&|\band\b)\s*${BODY_REF})*)`, "gi");
/** A Linear issue's URL anywhere in a description. */
const LINEAR_URL = /https:\/\/linear\.app\/[\w-]+\/issue\/([A-Za-z][A-Za-z0-9]{1,9}-\d+)\b/g;
const BODY_KEY = /([A-Za-z][A-Za-z0-9]{1,9}-\d+)\b/g;

/** Where a PR names its tickets, each key once: its title in brackets, then its branch, then its description. */
export interface TicketKeys {
  title: string[];
  branch: string[];
  body: string[];
}

/**
 * The keys a title names in brackets, then the ones only its branch names, then the ones only its description links
 * the way Linear does (`MAGIC`, `LINEAR_URL`), each once, in the order written.
 */
export function ticketKeysOf(title: string, branch: string, body = ""): TicketKeys {
  const inTitle = [...title.matchAll(BRACKET)].flatMap(([, inside]) => [...inside.matchAll(KEY)].map(([key]) => key));
  const fromTitle = [...new Set(inTitle)];
  const fromBranch = [...new Set([...branch.matchAll(BRANCH_KEY)].map(([, key]) => key.toUpperCase()))]
    .filter((key) => !fromTitle.includes(key));
  const named = [
    ...[...body.matchAll(MAGIC)].flatMap(([, refs]) => [...refs.matchAll(BODY_KEY)].map(([key]) => key)),
    ...[...body.matchAll(LINEAR_URL)].map(([, key]) => key),
  ].map((key) => key.toUpperCase());
  const fromBody = [...new Set(named)].filter((key) => !fromTitle.includes(key) && !fromBranch.includes(key));
  return { title: fromTitle, branch: fromBranch, body: fromBody };
}

/** Every key, in order: what Linear is asked about. */
export function allKeys(keys: TicketKeys): string[] {
  return [...keys.title, ...keys.branch, ...keys.body];
}

/** A key before Linear has been asked. */
export function unresolved(key: string): Ticket {
  return { key, url: null, title: null, state: null, state_type: null, state_color: null, found: null };
}

interface Issue {
  identifier: string;
  title: string;
  url: string;
  state: { name: string; type: string; color: string } | null;
}

export interface LinearAnswer<Data> {
  data?: Data | null;
  errors?: { message?: string; path?: unknown[] }[];
}

/**
 * One GraphQL call to Linear with the Worker's `LINEAR_API_KEY`. Null without the key, or when Linear does not answer:
 * a failed request, or an HTTP error other than 400, which carries GraphQL's own errors.
 */
export async function askLinear<Data>(
  query: string, variables: Record<string, unknown>, env: Pick<Env, "LINEAR_API_KEY">,
): Promise<LinearAnswer<Data> | null> {
  if (!isSet(env.LINEAR_API_KEY)) {
    return null;
  }
  try {
    const response = await fetch(LINEAR, {
      method: "POST",
      headers: { Authorization: env.LINEAR_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ query, variables }),
    });
    return response.ok || response.status === 400 ? await response.json() as LinearAnswer<Data> : null;
  } catch {
    return null;
  }
}

/**
 * Each key's issue in one Linear call. A key Linear says it has no issue for is false; any other failure leaves every
 * key unasked (null), so a Linear outage never reads as "Not found".
 */
export async function lookUpTickets(keys: string[], env: Env): Promise<Map<string, Ticket>> {
  const found = new Map<string, Ticket>();
  if (keys.length === 0) {
    return found;
  }
  const fields = keys.map((key, index) =>
    `t${index}: issue(id: ${JSON.stringify(key)}) { identifier title url state { name type color } }`);
  const answer = await askLinear<Record<string, Issue | null>>(`query { ${fields.join("\n")} }`, {}, env);
  if (!answer?.data) {
    return found;
  }
  const missing = new Set((answer.errors ?? [])
    .filter((error) => /not found/i.test(error.message ?? ""))
    .map((error) => error.path?.[0]));
  keys.forEach((key, index) => {
    const issue = answer.data?.[`t${index}`];
    if (issue) {
      found.set(key, {
        key: issue.identifier, url: issue.url, title: issue.title, state: issue.state?.name ?? null,
        state_type: issue.state?.type ?? null, state_color: issue.state?.color ?? null, found: true,
      });
    } else if (missing.has(`t${index}`)) {
      found.set(key, { ...unresolved(key), found: false });
    }
  });
  return found;
}

/**
 * The tickets a PR shows: its title's keys as Linear has them, a title's key Linear lacks as Not found, and a key only
 * the branch or description names only once Linear has it, since a branch's `fix-12` may be no ticket at all.
 */
export function resolvedTickets(keys: TicketKeys, issues: ReadonlyMap<string, Ticket>): Ticket[] {
  const fromTitle = keys.title.map((key) => issues.get(key) ?? unresolved(key));
  const linked = [...keys.branch, ...keys.body].flatMap((key) => {
    const issue = issues.get(key);
    return issue?.found ? [issue] : [];
  });
  return [...fromTitle, ...linked];
}

/**
 * The tickets a PRs-tab row shows: every ticket its title names that Linear has, in the title's order; without one, the
 * first its branch or description names that Linear has. Empty without one.
 */
export function rowTickets(keys: TicketKeys, tickets: readonly Ticket[]): Ticket[] {
  const found = tickets.filter((ticket) => ticket.found === true);
  const fromTitle = found.filter((ticket) => keys.title.includes(ticket.key));
  return fromTitle.length > 0 ? fromTitle : found.slice(0, 1);
}
