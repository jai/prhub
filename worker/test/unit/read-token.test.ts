import assert from "node:assert/strict";
import { afterEach, test } from "vitest";
import {
  graphql,
  mergedPullRequests,
  readsAsAnyone,
  postToGitHub,
  searchListings,
  sendToGitHub,
} from "../../src/github.ts";
import { env, gitHub } from "../support/read-token-responses.ts";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});
const EMPTY_SEARCH = {
  data: { search: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } },
};

test("the searches go with the read token and name the owner, never @me", async () => {
  const calls = gitHub(() => EMPTY_SEARCH);
  await searchListings(env());
  await mergedPullRequests(env(), "reviewed");
  assert.deepEqual(new Set(calls.map((call) => call.token)), new Set(["reader"]));
  const qs = calls.map((call) => String(call.q));
  assert.ok(
    qs.every((q) => !q.includes("@me")),
    qs.join("\n"),
  );
  assert.ok(qs.some((q) => q.includes("user-review-requested:jai")));
  assert.ok(qs.some((q) => q.includes("reviewed-by:jai -author:jai")));
});

test("without GITHUB_LOGIN the owner is GITHUB_TOKEN's user, not the read token's", async () => {
  const calls = gitHub(() => EMPTY_SEARCH);
  await searchListings(env({ GITHUB_LOGIN: undefined }));
  assert.equal(calls.find((call) => call.url.endsWith("/user"))?.token, "owner");
  assert.ok(calls.some((call) => String(call.q).includes("author:jai")));
});

test("every write goes with GITHUB_TOKEN", async () => {
  const calls = gitHub(() => ({ data: { resolveReviewThread: { thread: { id: "T1" } } } }));
  await postToGitHub("/repos/acme/app/issues/7/comments", { body: "Looks right." }, env());
  await sendToGitHub("PUT", "/repos/acme/app/pulls/7/merge", { merge_method: "squash" }, env());
  await graphql(
    `
      mutation ($thread: ID!) {
        resolveReviewThread(input: { threadId: $thread }) {
          thread {
            id
          }
        }
      }
    `,
    { thread: "T1" },
    env(),
  );
  assert.deepEqual(
    calls.map((call) => [call.method, call.token]),
    [
      ["POST", "owner"],
      ["PUT", "owner"],
      ["POST", "owner"],
    ],
  );
});

test("org and team membership checks go with GITHUB_TOKEN; other reads with the read token", () => {
  assert.equal(readsAsAnyone("/orgs/acme/members/octocat", {}), false);
  assert.equal(readsAsAnyone("/orgs/acme/teams/reviewers/memberships/octocat", {}), false);
  assert.equal(readsAsAnyone("/repos/acme/app/contents/.policy.yml", {}), true);
  assert.equal(readsAsAnyone("/orgs/acme/repos", {}), true);
});
