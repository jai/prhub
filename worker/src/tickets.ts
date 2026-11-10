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

/** The keys a title names in brackets, then the ones only its branch names, each once, in the order written. */
export function ticketKeysOf(title: string, branch: string): { title: string[]; branch: string[] } {
  const inTitle = [...title.matchAll(BRACKET)].flatMap(([, inside]) => [...inside.matchAll(KEY)].map(([key]) => key));
  const fromTitle = [...new Set(inTitle)];
  const fromBranch = [...new Set([...branch.matchAll(BRANCH_KEY)].map(([, key]) => key.toUpperCase()))]
    .filter((key) => !fromTitle.includes(key));
  return { title: fromTitle, branch: fromBranch };
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

/**
 * Each key's issue in one Linear call. A key Linear says it has no issue for is false; any other failure leaves every
 * key unasked (null), so a Linear outage never reads as "Not found".
 */
export async function lookUpTickets(keys: string[], env: Env): Promise<Map<string, Ticket>> {
  const found = new Map<string, Ticket>();
  if (keys.length === 0 || !isSet(env.LINEAR_API_KEY)) {
    return found;
  }
  const fields = keys.map((key, index) =>
    `t${index}: issue(id: ${JSON.stringify(key)}) { identifier title url state { name type color } }`);
  let answer: { data?: Record<string, Issue | null> | null; errors?: { message?: string; path?: unknown[] }[] };
  try {
    const response = await fetch(LINEAR, {
      method: "POST",
      headers: { Authorization: env.LINEAR_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ query: `query { ${fields.join("\n")} }` }),
    });
    if (!response.ok && response.status !== 400) {
      return found;
    }
    answer = await response.json() as typeof answer;
  } catch {
    return found;
  }
  if (!answer.data) {
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
 * the branch names only once Linear has it, since a branch's `fix-12` may be no ticket at all.
 */
export function resolvedTickets(
  keys: { title: string[]; branch: string[] }, issues: ReadonlyMap<string, Ticket>,
): Ticket[] {
  const fromTitle = keys.title.map((key) => issues.get(key) ?? unresolved(key));
  const fromBranch = keys.branch.flatMap((key) => {
    const issue = issues.get(key);
    return issue?.found ? [issue] : [];
  });
  return [...fromTitle, ...fromBranch];
}
