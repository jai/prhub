import type { Env } from "../../src/env.ts";
import { type Asked, type GraphqlRequest, stubFetch } from "./fake-fetch.ts";
import { env as envOf } from "./env.ts";

/** GitHub: `/user` names the token's owner, `answer` answers each GraphQL request, and any other call is accepted. */
export function gitHub(
  answer: (graphql: GraphqlRequest) => unknown = () => ({ data: {} }),
): Asked[] {
  return stubFetch((asked) => {
    if (asked.url.endsWith("/user")) {
      return Response.json({ login: asked.token === "owner" ? "jai" : "jai-bot-reviewer" });
    }
    if (asked.graphql) {
      return Response.json(answer(asked.graphql));
    }
    return new Response(null, { status: asked.url.includes(".policy.yml") ? 404 : 201 });
  });
}

export const env = (vars: Partial<Env> = {}) =>
  envOf({ GITHUB_TOKEN: "owner", GITHUB_READ_TOKEN: "reader", GITHUB_LOGIN: "jai", ...vars });
