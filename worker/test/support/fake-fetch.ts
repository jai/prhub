// The one way tests stand in for a service over HTTP. `stubFetch` puts a fake in place of the global `fetch` for one test
// (vitest's `unstubGlobals` puts the real one back); `fakeFetch` is the same fake for code that is handed its fetch.
// Each request is kept as `Asked`, its GraphQL read once here, so a fake answers by operation, variables and fields,
// never by searching the query's text.
import { vi } from "vitest";

/** One field of a GraphQL selection: its alias (its name when it has none), arguments, and what it selects. */
export interface GraphqlField {
  alias: string;
  name: string;
  /** Literal arguments as values; a `$variable` as the variable's value. */
  args: Record<string, unknown>;
  fields: GraphqlField[];
  /** The named fragments it spreads (`...Fields`). */
  spreads: string[];
}

export interface GraphqlRequest {
  /** The operation's name (`query PRHubUsers`), or null for an anonymous one. */
  operation: string | null;
  variables: Record<string, unknown>;
  /**
   * The operation's top-level fields. GitHub's batched reads name each PR in an aliased field (`p0: repository(…)`)
   * rather than in variables, so a fake answers those field by field.
   */
  fields: GraphqlField[];
  /** Every named fragment spread anywhere in the operation. */
  spreads: Set<string>;
}

/** A request as a fake sees it. */
export interface Asked {
  url: string;
  method: string;
  headers: Headers;
  /** The `Authorization` bearer token, or "" without one. */
  token: string;
  body: string | null;
  graphql: GraphqlRequest | null;
}

export type Answer = (asked: Asked) => Response | Promise<Response>;

/** What `fetch` was called with, read as `Asked`. */
export async function askedOf(input: RequestInfo | URL, init?: RequestInit): Promise<Asked> {
  const request = input instanceof Request ? input : null;
  const headers = new Headers(init?.headers ?? request?.headers);
  const body =
    typeof init?.body === "string" ? init.body : request ? await request.clone().text() : null;
  return {
    url: request ? request.url : String(input),
    method: init?.method ?? request?.method ?? "GET",
    headers,
    token: (headers.get("Authorization") ?? "").replace(/^Bearer /, ""),
    body,
    graphql: graphqlOf(body),
  };
}

/** A fetch for code that takes one: each request goes to `answer`, and is kept in `asked`. */
export function fakeFetch(answer: Answer): { fetch: typeof fetch; asked: Asked[] } {
  const asked: Asked[] = [];
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const one = await askedOf(input, init);
    asked.push(one);
    return answer(one);
  }) as typeof fetch;
  return { fetch: fetcher, asked };
}

/** The global `fetch` replaced for this test by `answer`; returns every request, in order. */
export function stubFetch(answer: Answer): Asked[] {
  const { fetch, asked } = fakeFetch(answer);
  vi.stubGlobal("fetch", fetch);
  return asked;
}

/** A GraphQL request's body, read; null when the body is not one. */
export function graphqlOf(body: string | null): GraphqlRequest | null {
  if (!body) {
    return null;
  }
  let parsed: { query?: unknown; variables?: Record<string, unknown> };
  try {
    parsed = JSON.parse(body) as typeof parsed;
  } catch {
    return null;
  }
  if (typeof parsed?.query !== "string") {
    return null;
  }
  return parseOperation(parsed.query, parsed.variables ?? {});
}

/** An anonymous operation's root field (`search`, `viewer`, `repository`…): what it asks for, as GitHub's carry no name. */
export const rootOf = (graphql: GraphqlRequest | null | undefined) =>
  graphql?.fields[0]?.name ?? "";

/** The search phrase (the `q` variable) a GraphQL request carried, or "" for none. */
export const searchOf = (asked: Asked) => String(asked.graphql?.variables.q ?? "");

/** All fields named `name` at any depth, in document order. */
export function fieldsNamed(fields: GraphqlField[], name: string): GraphqlField[] {
  return fields.flatMap((field) => [
    ...(field.name === name ? [field] : []),
    ...fieldsNamed(field.fields, name),
  ]);
}

// --- The reader: just enough GraphQL for the Worker's own queries ----------------------------------------------------

const TOKEN =
  /\s+|,|#[^\n]*|(\.\.\.|[{}()[\]:!=@$])|("(?:[^"\\]|\\.)*")|(-?\d+(?:\.\d+)?)|([_A-Za-z]\w*)/y;

function tokensOf(query: string): string[] {
  const tokens: string[] = [];
  TOKEN.lastIndex = 0;
  while (TOKEN.lastIndex < query.length) {
    const at = TOKEN.lastIndex;
    const match = TOKEN.exec(query);
    if (!match) {
      throw new Error(`GraphQL the fake can't read at ${at}: ${query.slice(at, at + 20)}`);
    }
    const token = match[1] ?? match[2] ?? match[3] ?? match[4];
    if (token !== undefined) {
      tokens.push(token);
    }
  }
  return tokens;
}

function parseOperation(query: string, variables: Record<string, unknown>): GraphqlRequest {
  const tokens = tokensOf(query);
  let at = 0;
  const peek = () => tokens[at];
  const take = () => tokens[at++];
  const skipBalanced = (open: string, close: string) => {
    let depth = 0;
    do {
      const token = take();
      depth += token === open ? 1 : token === close ? -1 : 0;
    } while (depth > 0 && at < tokens.length);
  };
  const spreads = new Set<string>();
  const value = (): unknown => {
    const token = take();
    if (token === "$") {
      return variables[take()];
    }
    if (token === "[" || token === "{") {
      at -= 1;
      skipBalanced(token, token === "[" ? "]" : "}");
      return null;
    }
    if (token.startsWith('"')) {
      return JSON.parse(token) as string;
    }
    return /^-?\d/.test(token) ? Number(token) : token;
  };
  const selection = (): { fields: GraphqlField[]; spreads: string[] } => {
    const fields: GraphqlField[] = [];
    const named: string[] = [];
    take(); // {
    while (peek() !== "}") {
      if (peek() === "...") {
        take();
        if (peek() === "on" || peek() === "{") {
          if (peek() === "on") {
            take();
            take();
          }
          const inline = selection();
          fields.push(...inline.fields);
          named.push(...inline.spreads);
        } else {
          const name = take();
          named.push(name);
          spreads.add(name);
        }
        continue;
      }
      const first = take();
      const [alias, name] = peek() === ":" ? (take(), [first, take()]) : [first, first];
      const args: Record<string, unknown> = {};
      if (peek() === "(") {
        take();
        while (peek() !== ")") {
          const key = take();
          take(); // :
          args[key] = value();
        }
        take();
      }
      while (peek() === "@") {
        take();
        take();
        if (peek() === "(") {
          skipBalanced("(", ")");
        }
      }
      const inner = peek() === "{" ? selection() : { fields: [], spreads: [] };
      fields.push({ alias, name, args, fields: inner.fields, spreads: inner.spreads });
    }
    take(); // }
    return { fields, spreads: named };
  };
  let operation: string | null = null;
  if (peek() === "query" || peek() === "mutation" || peek() === "subscription") {
    take();
    if (peek() !== "(" && peek() !== "{") {
      operation = take();
    }
    if (peek() === "(") {
      skipBalanced("(", ")");
    }
  }
  return { operation, variables, fields: selection().fields, spreads };
}
