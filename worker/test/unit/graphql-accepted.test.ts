// GitHub refuses a whole query, with errors and no data, when one selection asks for a field twice under one name with
// different arguments. A PR's detail did: `labels(first: 50)` beside the `labels(first: 20)` that came in with the
// people's fields, and every detail read failed. The fakes answered whatever was asked, so no test saw it. Now the fake
// refuses as GitHub does (fake-fetch.ts), and these tests hold the Worker's own PR queries to it.
import assert from "node:assert/strict";
import { test } from "vitest";
import { readPullRequests } from "../../src/github.ts";
import { prId, repoOf } from "../../src/ids.ts";
import { LABEL_FIELDS, PEOPLE_FIELDS } from "../../src/policy-people.ts";
import { statesQuery } from "../../src/pr-states.ts";
import { graphqlOf, stubFetch } from "../support/fake-fetch.ts";
import { prNode } from "../support/pr-node.ts";
import { env, gitHub } from "../support/read-token-responses.ts";

const refusalOf = (query: string) => graphqlOf(JSON.stringify({ query }))?.refusal;
const REF = { id: prId(repoOf("acme/app"), 7), repo: repoOf("acme/app"), number: 7 };

test("a field asked twice with different arguments is refused, in a selection or through its fragments", () => {
  assert.match(
    refusalOf(
      "query { pr { labels(first: 50) { nodes { name } } labels(first: 20) { nodes { name } } } }",
    ) ?? "",
    /^Field 'labels' has an argument conflict/,
  );
  assert.match(
    refusalOf(`query { pr { ...A labels(first: 50) { nodes { name } } } }
      fragment A on PullRequest { labels(first: 20) { nodes { name } } }`) ?? "",
    /^Field 'labels' has an argument conflict/,
  );
  assert.match(
    refusalOf(
      "query { pr { reviews(last: 5) { nodes { author { login(size: 1) } author { login } } } } }",
    ) ?? "",
    /^Field 'login' has an argument conflict/,
  );
  assert.match(
    refusalOf("query { pr { some: reviews(last: 5) { id } some: comments(last: 5) { id } } }") ??
      "",
    /^Field 'some' has a field conflict/,
  );
});

test("the same field twice with the same arguments, or under two names, is accepted", () => {
  assert.equal(
    refusalOf(
      "query($n: Int!) { pr { labels(first: $n) { nodes { name } } labels(first: $n) { nodes { color } } } }",
    ),
    null,
  );
  assert.equal(
    refusalOf(
      "query { pr { comments(first: 100) { nodes { id } } mine: comments(last: 100) { nodes { id } } } }",
    ),
    null,
  );
});

test("the fake answers a refused query as GitHub does: errors, no data, whatever the test would have said", async () => {
  stubFetch(() => Response.json({ data: { viewer: { login: "jai" } } }));
  const response = await fetch("https://api.github.com/graphql", {
    method: "POST",
    body: JSON.stringify({ query: "query { viewer { avatarUrl(size: 1) avatarUrl(size: 2) } }" }),
  });
  const answer = (await response.json()) as { data?: unknown; errors?: { message: string }[] };
  assert.equal(answer.data, undefined);
  assert.match(answer.errors?.[0]?.message ?? "", /argument conflict/);
});

test("a PR's labels are asked for in one place: the people's fields carry the shared selection", () => {
  assert.ok(PEOPLE_FIELDS.includes(LABEL_FIELDS));
  assert.equal(PEOPLE_FIELDS.split("labels(").length - 1, 1);
});

test("a PR's detail query is one GitHub accepts, read in one query or split between two tokens", async () => {
  const { viewerDidAuthor: _a, files: _f, ...shared } = prNode();
  for (const vars of [{}, { GITHUB_READ_TOKEN: undefined }]) {
    const calls = gitHub((graphql) => ({
      data: {
        p0: { pullRequest: graphql.spreads.has("Fields") ? { ...prNode(), ...shared } : prNode() },
      },
    }));
    const read = await readPullRequests([REF], env(vars), new Set(), async () => new Map());
    const queries = calls.filter((call) => call.graphql);
    assert.ok(
      queries.some((call) => call.graphql?.spreads.has("Fields")),
      "the detail's fields were asked for",
    );
    assert.deepEqual(
      queries.map((call) => call.graphql?.refusal),
      queries.map(() => null),
    );
    assert.ok(read.get(REF.id)?.detail, "and the detail was read");
  }
});

test("the states query is one GitHub accepts", () => {
  const { query } = statesQuery([REF.id, prId(repoOf("acme/web"), 9)]);
  assert.equal(refusalOf(query), null);
});
