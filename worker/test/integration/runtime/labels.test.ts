// A PR's labels through the Worker's own route.
import { exports } from "cloudflare:workers";
import { expect, test, vi } from "vitest";
import { authorization } from "./values.ts";

const URL = "https://prhub.test/prs/acme/app/7/labels";

test("the labels route answers the repo's labels and whether they may be changed, and counts its GitHub calls", async () => {
  const asked: string[] = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
    const url = String(input instanceof Request ? input.url : input);
    asked.push(url);
    return url.endsWith("/graphql")
      ? Response.json({ data: { repository: { pullRequest: { viewerCanLabel: true } } } })
      : Response.json([
          { name: "bug", color: "d73a4a", description: "Something isn't working" },
          { name: "API", color: "0e8a16", description: null },
        ]);
  });
  const response = await exports.default.fetch(URL, { headers: authorization });
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({
    labels: [
      { name: "API", color: "0e8a16", description: null },
      { name: "bug", color: "d73a4a", description: "Something isn't working" },
    ],
    canEdit: true,
  });
  expect(response.headers.get("Server-Timing")).toBe('github;desc="github calls";dur=2');
  expect(asked.toSorted()).toEqual([
    "https://api.github.com/graphql",
    "https://api.github.com/repos/acme/app/labels?per_page=100&page=1",
  ]);
});

test("the labels route is behind the bearer, takes only a GET, and asks GitHub for no PR number it can't have", async () => {
  expect((await exports.default.fetch(URL)).status).toBe(401);
  const post = await exports.default.fetch(URL, { method: "POST", headers: authorization });
  expect(post.status).toBe(404);
  for (const number of ["0", "2147483648"]) {
    const response = await exports.default.fetch(
      `https://prhub.test/prs/acme/app/${number}/labels`,
      { headers: authorization },
    );
    expect(response.status).toBe(404);
  }
});
