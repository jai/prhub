import type { Env } from "../../src/env.ts";
import { prId, type RepoFullName } from "../../src/ids.ts";
import { prNode } from "./pr-node.ts";

const POLICY = `policy:
  approval: [reviewers]
approval_rules:
  - name: reviewers
    requires: { count: 1, teams: [acme/backend] }
`;
const ETAG = '"policy-1"';
export const env = { GITHUB_TOKEN: "t", GITHUB_LOGIN: "jai" } as Env;
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
/** Stands in for GitHub; answers each call and keeps what was asked, and whether it would count against the hour. */
export function stubGitHub() {
  const calls: { kind: string; counted: boolean }[] = [];
  globalThis.fetch = (async (input: string, init?: RequestInit) => {
    const url = new URL(String(input));
    const etag = (init?.headers as Record<string, string> | undefined)?.["If-None-Match"];
    if (url.pathname === "/graphql") {
      const { query } = JSON.parse(String(init?.body)) as { query: string };
      calls.push({ kind: "graphql", counted: true });
      const aliases = [...query.matchAll(/(p\d+): repository/g)].map((match) => match[1] as string);
      return Response.json({
        data: Object.fromEntries(
          aliases.map((alias, index) => [
            alias,
            { pullRequest: prNode({ number: 7 + index, latestReviews: approved }) },
          ]),
        ),
      });
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
  }) as typeof fetch;
  return calls;
}
