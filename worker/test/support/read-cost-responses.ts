import { prId, type RepoFullName } from "../../src/ids.ts";
import { env as envOf } from "./env.ts";
import { stubFetch } from "./fake-fetch.ts";
import { prNode } from "./pr-node.ts";

const POLICY = `policy:
  approval: [reviewers]
approval_rules:
  - name: reviewers
    requires: { count: 1, teams: [acme/backend] }
`;
const ETAG = '"policy-1"';
export const env = envOf({ GITHUB_TOKEN: "t", GITHUB_LOGIN: "jai" });
const repo = "acme/app" as RepoFullName;
export const ref = (number: number) => ({ id: prId(repo, number), repo, number });
const approved = {
  nodes: [
    {
      author: { login: "sam", avatarUrl: "a" },
      state: "APPROVED",
      submittedAt: "2026-11-06T04:00:00Z",
    },
  ],
};
/**
 * Stands in for GitHub; answers each call and keeps what was asked, and whether it would count against the hour.
 * `graphqlAnswer` may change a GraphQL answer before it goes.
 */
export function stubGitHub(
  graphqlAnswer: (answer: { data: Record<string, unknown> }) => unknown = (answer) => answer,
): { kind: string; counted: boolean }[] {
  const calls: { kind: string; counted: boolean }[] = [];
  stubFetch((asked) => {
    const url = new URL(asked.url);
    const etag = asked.headers.get("If-None-Match");
    if (asked.graphql) {
      calls.push({ kind: "graphql", counted: true });
      const prs = asked.graphql.fields.filter((field) => field.name === "repository");
      return Response.json(
        graphqlAnswer({
          data: Object.fromEntries(
            prs.map((field, index) => [
              field.alias,
              { pullRequest: prNode({ number: 7 + index, latestReviews: approved }) },
            ]),
          ),
        }),
      );
    }
    if (url.pathname.endsWith("/contents/.policy.yml")) {
      calls.push({ kind: "policy", counted: etag !== ETAG });
      return etag === ETAG
        ? new Response(null, { status: 304 })
        : new Response(POLICY, { headers: { ETag: ETAG } });
    }
    if (url.pathname.includes("/teams/")) {
      calls.push({ kind: "membership", counted: etag !== '"team-1"' });
      return etag === '"team-1"'
        ? new Response(null, { status: 304 })
        : Response.json({ state: "active" }, { headers: { ETag: '"team-1"' } });
    }
    throw new Error(`unexpected ${url}`);
  });
  return calls;
}
