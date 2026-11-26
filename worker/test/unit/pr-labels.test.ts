// A PR's labels: the repo's list with whether the person may change them, and the two writes that put one on or off.
import assert from "node:assert/strict";
import { test } from "vitest";
import { readPullRequests } from "../../src/github.ts";
import { prId, repoOf } from "../../src/ids.ts";
import { labelsRoute, MAX_REPO_LABELS } from "../../src/pr-labels.ts";
import { parseWrite } from "../../src/write-input.ts";
import { actForAsk, writeToGitHub } from "../../src/write.ts";
import { env as envOf } from "../support/env.ts";
import { type Answer, type Asked, fieldsNamed, stubFetch } from "../support/fake-fetch.ts";
import { env } from "../support/read-token-responses.ts";

const REPO = repoOf("acme/app");
const API = "https://api.github.com";
const LIST = `${API}/repos/acme/app/labels?per_page=100&page=`;
const ON_PR = `${API}/repos/acme/app/issues/7/labels`;

const label = (name: string, description: string | null = null, color = "d73a4a") => ({
  id: 1,
  node_id: "LA_1",
  url: `${API}/repos/acme/app/labels/${encodeURIComponent(name)}`,
  name,
  color,
  default: false,
  description,
});

/** GitHub with these repo labels, a hundred a page, and this answer to whether the viewer may label PR 7. */
function gitHubWith(labels: object[], canLabel: boolean | null = true): Asked[] {
  return stubFetch((asked) => {
    if (asked.graphql) {
      return Response.json({
        data: {
          repository: { pullRequest: canLabel === null ? null : { viewerCanLabel: canLabel } },
        },
      });
    }
    const page = Number(new URL(asked.url).searchParams.get("page"));
    return Response.json(labels.slice((page - 1) * 100, page * 100));
  });
}

const sent = (calls: Asked[]) =>
  calls.map((call) => [call.method, call.url.replace(API, ""), call.body]);

const refusalOf = async (response: Response | null) =>
  response ? [response.status, ((await response.json()) as { error: string }).error] : null;

// --- The names a write may carry -----------------------------------------------------------------------------------

test("a label write names one label, trimmed", () => {
  assert.deepEqual(parseWrite({ kind: "label_add", name: "  needs review " }), {
    kind: "label_add",
    name: "needs review",
  });
  assert.deepEqual(parseWrite({ kind: "label_remove", name: ":rocket: ship it" }), {
    kind: "label_remove",
    name: ":rocket: ship it",
  });
  assert.deepEqual(parseWrite({ kind: "label_add", name: "a".repeat(200) }), {
    kind: "label_add",
    name: "a".repeat(200),
  });
});

test("a label write with no name, a name too long or a control character in it is no write", () => {
  for (const kind of ["label_add", "label_remove"]) {
    for (const name of [
      "",
      "   ",
      "a".repeat(201),
      "bug\nfix",
      "bug\u0000",
      "bug\u007ffix",
      7,
      null,
    ]) {
      assert.equal(parseWrite({ kind, name }), null, `${kind} ${JSON.stringify(name)}`);
    }
    assert.equal(parseWrite({ kind }), null);
  }
});

// --- Adding --------------------------------------------------------------------------------------------------------

test("a label is added under the repo's own spelling, once the repo is asked that it has one", async () => {
  const calls = stubFetch((asked) =>
    asked.method === "POST"
      ? Response.json([label("Needs Review")])
      : Response.json(label("Needs Review")),
  );
  assert.equal(
    await writeToGitHub(REPO, 7, { kind: "label_add", name: "needs review" }, env()),
    null,
  );
  assert.deepEqual(sent(calls), [
    ["GET", "/repos/acme/app/labels/needs%20review", null],
    ["POST", "/repos/acme/app/issues/7/labels", JSON.stringify({ labels: ["Needs Review"] })],
  ]);
  assert.deepEqual(
    calls.map((call) => call.token),
    ["reader", "owner"],
    "the write goes as the person",
  );
});

test("a label the repo has not got is refused, and nothing is posted: GitHub would make it", async () => {
  const calls = stubFetch(() => Response.json({ message: "Not Found" }, { status: 404 }));
  const refused = await writeToGitHub(REPO, 7, { kind: "label_add", name: "p0/urgent" }, env());
  assert.deepEqual(await refusalOf(refused), [422, 'This repo has no label named "p0/urgent".']);
  assert.deepEqual(sent(calls), [["GET", "/repos/acme/app/labels/p0%2Furgent", null]]);
});

test("a label GitHub answers under another name is not the one asked for", async () => {
  const calls = stubFetch(() => Response.json(label("bug report")));
  const refused = await writeToGitHub(REPO, 7, { kind: "label_add", name: "bug" }, env());
  assert.equal(refused?.status, 422);
  assert.equal(calls.length, 1);
});

test("GitHub's refusal of an add reaches the phone in GitHub's words, or the Worker's where it gave none", async () => {
  const answers: Answer[] = [
    () => Response.json({ message: "Must have admin rights to Repository." }, { status: 403 }),
    () => new Response(null, { status: 403 }),
  ];
  const words = [];
  for (const answer of answers) {
    stubFetch((asked) => (asked.method === "POST" ? answer(asked) : Response.json(label("bug"))));
    words.push(
      await refusalOf(await writeToGitHub(REPO, 7, { kind: "label_add", name: "bug" }, env())),
    );
  }
  assert.deepEqual(words, [
    [403, "Must have admin rights to Repository."],
    [403, "GitHub didn't let this Worker do that. Check the GitHub App's access to this repo."],
  ]);
});

test("a repo the label can't be read from refuses the add with that status, and nothing is posted", async () => {
  const calls = stubFetch(() => new Response(null, { status: 403 }));
  const refused = await writeToGitHub(REPO, 7, { kind: "label_add", name: "bug" }, env());
  assert.equal(refused?.status, 403);
  assert.equal(calls.length, 1);
});

// --- Removing ------------------------------------------------------------------------------------------------------

test("a label is taken off by name, encoded into the path", async () => {
  const calls = stubFetch(() => Response.json([]));
  assert.equal(
    await writeToGitHub(REPO, 7, { kind: "label_remove", name: "p0/urgent: now?" }, env()),
    null,
  );
  assert.deepEqual(
    calls.map((call) => [call.method, call.url, call.token]),
    [["DELETE", `${ON_PR}/p0%2Furgent%3A%20now%3F`, "owner"]],
  );
});

test("a label that is already off the PR counts as removed", async () => {
  stubFetch(() => Response.json({ message: "Label does not exist" }, { status: 404 }));
  assert.equal(await writeToGitHub(REPO, 7, { kind: "label_remove", name: "bug" }, env()), null);
});

test("a PR GitHub can't find, or one the person may not label, refuses the remove", async () => {
  stubFetch(() => Response.json({ message: "Not Found" }, { status: 404 }));
  const missing = await writeToGitHub(REPO, 7, { kind: "label_remove", name: "bug" }, env());
  assert.deepEqual(await refusalOf(missing), [404, "Not Found"]);

  stubFetch(() => new Response(null, { status: 403 }));
  const refused = await writeToGitHub(REPO, 7, { kind: "label_remove", name: "bug" }, env());
  assert.deepEqual(await refusalOf(refused), [
    403,
    "GitHub didn't let this Worker do that. Check the GitHub App's access to this repo.",
  ]);
});

// --- Ask -----------------------------------------------------------------------------------------------------------

test("Ask's agent can't change labels, and still does what it could", async () => {
  const calls = stubFetch(() => Response.json({}, { status: 201 }));
  for (const kind of ["label_add", "label_remove"]) {
    assert.equal(
      await actForAsk(REPO, 7, { kind, name: "bug" }, env()),
      "Labels are changed in the app, not by Ask.",
    );
  }
  assert.equal(calls.length, 0);
  assert.equal(await actForAsk(REPO, 7, { kind: "comment", body: "Looks right." }, env()), null);
  assert.deepEqual(
    calls.map((call) => call.url),
    [`${API}/repos/acme/app/issues/7/comments`],
  );
  assert.equal(
    await actForAsk(REPO, 7, { kind: "no_such" }, env()),
    "That is not something the viewer can post.",
  );
});

// --- The repo's labels ---------------------------------------------------------------------------------------------

test("the labels route lists the repo's labels by name whatever their case, and says the person may label", async () => {
  const calls = gitHubWith([
    label("bug", "Something isn't working"),
    label("Zebra", ""),
    label("api", null, "0e8a16"),
    label("Bug fix"),
  ]);
  const response = await labelsRoute(REPO, 7, env());
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(await response.json(), {
    labels: [
      { name: "api", color: "0e8a16", description: null },
      { name: "bug", color: "d73a4a", description: "Something isn't working" },
      { name: "Bug fix", color: "d73a4a", description: null },
      { name: "Zebra", color: "d73a4a", description: null },
    ],
    canEdit: true,
  });
  const graphql = calls.find((call) => call.graphql);
  assert.deepEqual(graphql?.graphql?.variables, { owner: "acme", name: "app", number: 7 });
  assert.equal(fieldsNamed(graphql?.graphql?.fields ?? [], "viewerCanLabel").length, 1);
});

test("someone who may not label the PR is told so, with the labels all the same", async () => {
  gitHubWith([label("bug")], false);
  const answer = (await (await labelsRoute(REPO, 7, env())).json()) as {
    labels: unknown[];
    canEdit: boolean;
  };
  assert.equal(answer.canEdit, false);
  assert.equal(answer.labels.length, 1);
});

test("a repo's labels are read a hundred a page until a page is short", async () => {
  const names = Array.from({ length: 230 }, (_, at) => `label-${String(at).padStart(3, "0")}`);
  const calls = gitHubWith(names.toReversed().map((name) => label(name)));
  const answer = (await (await labelsRoute(REPO, 7, env())).json()) as {
    labels: { name: string }[];
  };
  assert.deepEqual(
    answer.labels.map((one) => one.name),
    names,
  );
  assert.deepEqual(
    calls.filter((call) => !call.graphql).map((call) => call.url),
    [`${LIST}1`, `${LIST}2`, `${LIST}3`],
  );
});

test("a repo with more labels than the route serves is cut at 500, and asked for no more", async () => {
  const labels = Array.from({ length: 720 }, (_, at) => label(`l${at}`));
  const calls = gitHubWith(labels);
  const answer = (await (await labelsRoute(REPO, 7, env())).json()) as { labels: unknown[] };
  assert.equal(answer.labels.length, MAX_REPO_LABELS);
  assert.equal(calls.filter((call) => !call.graphql).length, 5);
});

test("whether the person may label is asked as the person, never as the read token's account", async () => {
  const calls = gitHubWith([label("bug")]);
  await labelsRoute(REPO, 7, env());
  assert.deepEqual(calls.map((call) => [call.graphql ? "graphql" : "labels", call.token]).sort(), [
    ["graphql", "owner"],
    ["labels", "reader"],
  ]);

  const alice = envOf({ GITHUB_TOKEN: "ghu_alice", SIGNED_IN_USER_ID: "1001" });
  const hosted = gitHubWith([label("bug")]);
  await labelsRoute(REPO, 7, alice);
  assert.deepEqual(
    hosted.map((call) => call.token),
    ["ghu_alice", "ghu_alice"],
    "a hosted person reads with their own token alone",
  );
});

test("a PR or repo GitHub has not got for the person is not found", async () => {
  gitHubWith([label("bug")], null);
  const missing = await labelsRoute(REPO, 7, env());
  assert.equal(missing.status, 404);
  assert.deepEqual(await missing.json(), {
    error: { code: "not_found", message: "no such pull request" },
  });

  stubFetch((asked) =>
    asked.graphql
      ? Response.json({ data: { repository: null }, errors: [{ type: "NOT_FOUND" }] })
      : Response.json({ message: "Not Found" }, { status: 404 }),
  );
  assert.equal((await labelsRoute(REPO, 7, env())).status, 404);
});

test("GitHub failing either read fails the route, with no half answer", async () => {
  stubFetch((asked) =>
    asked.graphql ? new Response(null, { status: 502 }) : Response.json([label("bug")]),
  );
  const failed = await labelsRoute(REPO, 7, env());
  assert.equal(failed.status, 502);
  assert.deepEqual(await failed.json(), {
    error: { code: "github_unavailable", message: "GitHub could not be asked" },
  });

  stubFetch((asked) =>
    asked.graphql
      ? Response.json({ data: { repository: { pullRequest: { viewerCanLabel: true } } } })
      : new Response(null, { status: 500 }),
  );
  assert.equal((await labelsRoute(REPO, 7, env())).status, 500);
});

// --- The detail's labels -------------------------------------------------------------------------------------------

test("a PR's detail asks for up to 50 of its labels", async () => {
  const calls = stubFetch((asked) =>
    asked.graphql ? Response.json({ data: {} }) : Response.json({ login: "jai" }),
  );
  await readPullRequests([{ id: prId(REPO, 7), repo: REPO, number: 7 }], env()).catch(() => null);
  // The labels are in the query's fragment, which the fake's reader keeps no fields of: the query's own text says.
  const queries = calls
    .filter((call) => call.graphql)
    .map((call) => (JSON.parse(call.body ?? "{}") as { query: string }).query)
    .filter((query) => query.includes("labels("));
  assert.ok(queries.length > 0);
  for (const query of queries) {
    assert.match(query, /\blabels\(first: 50\) \{ nodes \{ name color \} \}/);
  }
});
