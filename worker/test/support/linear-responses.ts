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

/** Linear as a stand-in: the users query, and `commentCreate` answered by `comment`. */
export function linear(
  comment: (body: { query: string; variables?: Record<string, unknown> }) => unknown = () => ({}),
) {
  const asked: { query: string; variables?: Record<string, unknown> }[] = [];
  globalThis.fetch = (async (_url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body)) as {
      query: string;
      variables?: Record<string, unknown>;
    };
    asked.push(body);
    return Response.json(
      body.query.includes("users(")
        ? { data: { users: { nodes: USERS, pageInfo: { hasNextPage: false, endCursor: null } } } }
        : comment(body),
    );
  }) as typeof fetch;
  return asked;
}

export const KEY = { LINEAR_API_KEY: "lin_api_synthetic" };
