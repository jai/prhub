import { type GraphqlRequest, stubFetch } from "./fake-fetch.ts";

export const USERS = [
  {
    name: "Octo Bot",
    displayName: "octobot",
    url: "https://linear.app/acme/profiles/octobot",
    active: true,
    app: true,
  },
  {
    name: "Alex Doe",
    displayName: "alex",
    url: "https://linear.app/acme/profiles/alex",
    active: true,
  },
  {
    name: "Sam Roe",
    displayName: "sam.r",
    url: "https://linear.app/acme/profiles/sam.r",
    active: true,
  },
  {
    name: "Sam Rowe",
    displayName: "sam.rowe",
    url: "https://linear.app/acme/profiles/sam.rowe",
    active: true,
  },
  {
    name: "Old Bot",
    displayName: "oldbot",
    url: "https://linear.app/acme/profiles/oldbot",
    active: false,
  },
];

/** Linear as a stand-in: `PRHubUsers` answered with `USERS`, every other operation by `answer`. Returns what was asked. */
export function linear(
  answer: (graphql: GraphqlRequest) => unknown = () => ({}),
): GraphqlRequest[] {
  const asked: GraphqlRequest[] = [];
  stubFetch((request) => {
    const graphql = request.graphql!;
    asked.push(graphql);
    return Response.json(
      graphql.operation === "PRHubUsers"
        ? { data: { users: { nodes: USERS, pageInfo: { hasNextPage: false, endCursor: null } } } }
        : answer(graphql),
    );
  });
  return asked;
}

export const KEY = { LINEAR_API_KEY: "lin_api_synthetic" };
