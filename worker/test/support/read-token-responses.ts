import type { Env } from "../../src/env.ts";

interface Call {
  url: string;
  token: string;
  method: string;
  query: string;
  q: unknown;
}

/** Every GitHub call, with the token it went with; `answer` says what GitHub answers a GraphQL query. */
export function gitHub(answer: (query: string) => unknown = () => ({ data: {} })): Call[] {
  const calls: Call[] = [];
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    const token = new Headers(init.headers).get("authorization")?.replace("Bearer ", "") ?? "";
    const body =
      typeof init.body === "string"
        ? (JSON.parse(init.body) as { query?: string; variables?: { q?: unknown } })
        : {};
    calls.push({
      url,
      token,
      method: init.method ?? "GET",
      query: body.query ?? "",
      q: body.variables?.q,
    });
    if (url.endsWith("/user")) {
      return Response.json({ login: token === "owner" ? "jai" : "jai-bot-reviewer" });
    }
    if (url.endsWith("/graphql")) {
      return Response.json(answer(body.query ?? ""));
    }
    return new Response(null, { status: url.includes(".policy.yml") ? 404 : 201 });
  }) as typeof fetch;
  return calls;
}
export const env = (vars: Partial<Env> = {}) =>
  ({ GITHUB_TOKEN: "owner", GITHUB_READ_TOKEN: "reader", GITHUB_LOGIN: "jai", ...vars }) as Env;
