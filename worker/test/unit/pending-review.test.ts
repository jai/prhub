import assert from "node:assert/strict";
import { test } from "vitest";
import { readPullRequests } from "../../src/github.ts";
import { prId, repoOf } from "../../src/ids.ts";
import { writeToGitHub } from "../../src/write.ts";
import { type Asked, rootOf, stubFetch } from "../support/fake-fetch.ts";
import { prNode, readPr as read } from "../support/pr-node.ts";
import { env, gitHub } from "../support/read-token-responses.ts";

// --- Reading the unsent review -------------------------------------------------------------------------------------

const octocat = { login: "octocat", avatarUrl: "https://avatars.example/octocat" };
const jai = { login: "jai", avatarUrl: "https://avatars.example/jai" };
const comment = (id: string, author: typeof jai, body: string, state?: string) => ({
  id,
  author,
  body,
  createdAt: "2026-11-06T05:00:00Z",
  ...(state ? { state } : {}),
});
const thread = (
  id: string,
  diffSide: string,
  comments: ReturnType<typeof comment>[],
  fields: object = {},
) => ({
  id,
  isResolved: false,
  isOutdated: false,
  viewerCanResolve: true,
  viewerCanUnresolve: false,
  path: "src/checkout/payments.ts",
  line: 12,
  diffSide,
  comments: { nodes: comments },
  ...fields,
});
const pending = (id: string, body: string, fields: object = {}) => ({
  id,
  path: "src/checkout/payments.ts",
  line: 12,
  outdated: false,
  subjectType: "LINE",
  body,
  createdAt: "2026-11-06T06:00:00Z",
  ...fields,
});

/** A posted thread with jai's unsent reply, a thread he started and has not sent, and his unsent review. */
const WITH_PENDING = {
  reviews: {
    nodes: [
      {
        id: "PRR_1",
        author: octocat,
        state: "COMMENTED",
        body: "",
        submittedAt: "2026-11-06T04:00:00Z",
      },
      { id: "PRR_2", author: jai, state: "PENDING", body: "Two things.", submittedAt: null },
    ],
  },
  reviewThreads: {
    nodes: [
      thread("PRRT_1", "RIGHT", [
        comment("PRRC_1", octocat, "Is the total in cents?", "SUBMITTED"),
        comment("PRRC_2", jai, "It is.", "PENDING"),
      ]),
      thread("PRRT_2", "LEFT", [comment("PRRC_3", jai, "This check went missing.", "PENDING")], {
        line: 40,
      }),
    ],
  },
  pendingReviews: {
    nodes: [
      {
        id: "PRR_2",
        body: "Two things.",
        comments: {
          nodes: [
            pending("PRRC_2", "It is."),
            pending("PRRC_3", "This check went missing.", { line: 40 }),
            pending("PRRC_4", "Needs a test.", { line: null, subjectType: "FILE" }),
          ],
        },
      },
    ],
  },
};

const PENDING_REVIEW = {
  id: "PRR_2",
  body: "Two things.",
  comments: [
    {
      id: "PRRC_2",
      path: "src/checkout/payments.ts",
      line: 12,
      side: "RIGHT",
      body: "It is.",
      createdAt: "2026-11-06T06:00:00Z",
      outdated: false,
      thread: "PRRT_1",
      file: false,
    },
    {
      id: "PRRC_3",
      path: "src/checkout/payments.ts",
      line: 40,
      side: "LEFT",
      body: "This check went missing.",
      createdAt: "2026-11-06T06:00:00Z",
      outdated: false,
      thread: null,
      file: false,
    },
    {
      id: "PRRC_4",
      path: "src/checkout/payments.ts",
      line: null,
      side: "RIGHT",
      body: "Needs a test.",
      createdAt: "2026-11-06T06:00:00Z",
      outdated: false,
      thread: null,
      file: true,
    },
  ],
};

test("a PR with no unsent review says so", () => {
  assert.equal(read().detail.pendingReview, null);
  assert.equal(read({ pendingReviews: { nodes: [] } }).detail.pendingReview, null);
});

test("the unsent review carries its comments: a reply names its thread, and each takes its thread's side", () => {
  assert.deepEqual(read(WITH_PENDING).detail.pendingReview, PENDING_REVIEW);
});

test("nothing unsent shows as posted: not the review, not its thread, not its reply", () => {
  const { detail } = read(WITH_PENDING);
  assert.deepEqual(
    detail.reviews.nodes.map((review) => review.id),
    ["PRR_1"],
  );
  assert.deepEqual(detail.reviewThreads.nodes, [
    thread("PRRT_1", "RIGHT", [comment("PRRC_1", octocat, "Is the total in cents?")]),
  ]);
});

test("a thread GitHub answers with no comments stays, as before", () => {
  const empty = thread("PRRT_9", "RIGHT", []);
  assert.deepEqual(read({ reviewThreads: { nodes: [empty] } }).detail.reviewThreads.nodes, [empty]);
});

test("an unsent comment whose thread was not read is on the right side and replies to nothing", () => {
  const { detail } = read({ ...WITH_PENDING, reviewThreads: { nodes: [] } });
  assert.deepEqual(
    detail.pendingReview?.comments.map((one) => [one.id, one.side, one.thread]),
    [
      ["PRRC_2", "RIGHT", null],
      ["PRRC_3", "RIGHT", null],
      ["PRRC_4", "RIGHT", null],
    ],
  );
});

const REF = { id: prId(repoOf("acme/app"), 7), repo: repoOf("acme/app"), number: 7 };

test("with a read token, the unsent review and its threads' sides are the owner's own read", async () => {
  // The read token's account sees the posted thread alone, and no comment's state says more than SUBMITTED.
  const {
    viewerDidAuthor: _a,
    files: _f,
    ...shared
  } = prNode({
    reviews: { nodes: [WITH_PENDING.reviews.nodes[0]] },
    reviewThreads: {
      nodes: [
        thread("PRRT_1", "RIGHT", [
          comment("PRRC_1", octocat, "Is the total in cents?", "SUBMITTED"),
        ]),
      ],
    },
  });
  const viewer = {
    viewerDidAuthor: false,
    repository: { viewerDefaultMergeMethod: "SQUASH" },
    files: { nodes: [] },
    pendingReviews: WITH_PENDING.pendingReviews,
    reviewThreads: {
      nodes: WITH_PENDING.reviewThreads.nodes.map((one) => ({
        id: one.id,
        viewerCanResolve: true,
        viewerCanUnresolve: false,
        diffSide: one.diffSide,
        comments: { nodes: one.comments.nodes.map(({ id, state }) => ({ id, state })) },
      })),
    },
  };
  const calls = gitHub((graphql) => ({
    data: { p0: { pullRequest: graphql.spreads.has("Fields") ? shared : viewer } },
  }));
  const detail = (await readPullRequests([REF], env(), new Set(), async () => new Map())).get(
    REF.id,
  )?.detail;
  assert.deepEqual(detail?.pendingReview, PENDING_REVIEW);
  assert.deepEqual(
    detail?.reviewThreads.nodes.map((one) => [one.id, one.comments.nodes.map(({ id }) => id)]),
    [["PRRT_1", ["PRRC_1"]]],
  );
  // The unsent review is asked for in the owner's query alone, under its own name beside the posted reviews.
  const queries = calls.filter((call) => call.graphql);
  assert.deepEqual(
    queries.map((call) => [call.token, call.body?.includes("pendingReviews: reviews(") ?? false]),
    [
      ["reader", false],
      ["owner", true],
    ],
  );
});

test("with a read token and no answer from the owner's read, there is no unsent review", async () => {
  const shared = prNode({ pendingReviews: WITH_PENDING.pendingReviews });
  gitHub((graphql) => ({
    data: { p0: graphql.spreads.has("Fields") ? { pullRequest: shared } : null },
  }));
  const read = await readPullRequests([REF], env(), new Set(), async () => new Map());
  assert.equal(read.get(REF.id)?.detail.pendingReview, null);
});

// --- Writing to it -------------------------------------------------------------------------------------------------

const REPO = repoOf("acme/app");
const NO_REVIEW = {
  repository: { pullRequest: { id: "PR_kwDOAcme7", reviews: { nodes: [] } } },
};
const reviewOf = (comments: unknown[] = []) => ({
  repository: {
    pullRequest: {
      id: "PR_kwDOAcme7",
      reviews: { nodes: [{ id: "PRR_2", viewerDidAuthor: true, comments: { nodes: comments } }] },
    },
  },
});
const TOOK: Record<string, unknown> = {
  addPullRequestReviewThread: { thread: { id: "PRRT_3" } },
  addPullRequestReview: { pullRequestReview: { id: "PRR_3" } },
  addPullRequestReviewThreadReply: { comment: { id: "PRRC_5" } },
  updatePullRequestReviewComment: { pullRequestReviewComment: { id: "PRRC_3" } },
  deletePullRequestReviewComment: { clientMutationId: null },
  submitPullRequestReview: { pullRequestReview: { id: "PRR_2" } },
  deletePullRequestReview: { clientMutationId: null },
};

/** GitHub taking every mutation; `found` is what it answers for the unsent review, `answers` what differs. */
function gitHubTaking(found: unknown = NO_REVIEW, answers: Record<string, unknown> = {}): Asked[] {
  return gitHub((graphql) => {
    const root = rootOf(graphql);
    if (root === "repository") {
      return { data: found };
    }
    return root in answers ? answers[root] : { data: { [root]: TOOK[root] } };
  });
}

/** Each GraphQL call as `[root field, variables]`, in order. */
const sent = (calls: Asked[]) =>
  calls
    .filter((call) => call.graphql)
    .map((call) => [rootOf(call.graphql), call.graphql?.variables]);

async function errorOf(response: Response | null): Promise<[number, string] | null> {
  return response && [response.status, ((await response.json()) as { error: string }).error];
}

const ADD = {
  kind: "pending_add",
  pullRequest: "PR_kwDOAcme7",
  body: "Check the total first.",
  path: "src/checkout/payments.ts",
  line: 12,
  side: "LEFT",
};

test("a comment joins the unsent review as a thread that names the PR and no review", async () => {
  const calls = gitHubTaking();
  assert.equal(await writeToGitHub(REPO, 7, ADD, env()), null);
  assert.deepEqual(sent(calls), [
    [
      "addPullRequestReviewThread",
      {
        pr: "PR_kwDOAcme7",
        path: "src/checkout/payments.ts",
        body: "Check the total first.",
        line: 12,
        side: "LEFT",
        subject: "LINE",
      },
    ],
  ]);
  assert.deepEqual(
    calls.map((call) => call.token),
    ["owner"],
  );
  assert.doesNotMatch(calls[0]?.body ?? "", /pullRequestReviewId/);
});

test("a comment on the whole file names no line and no side", async () => {
  const calls = gitHubTaking();
  const { line: _line, side: _side, ...whole } = ADD;
  assert.equal(await writeToGitHub(REPO, 7, { ...whole, file: true }, env()), null);
  assert.deepEqual(sent(calls), [
    [
      "addPullRequestReviewThread",
      {
        pr: "PR_kwDOAcme7",
        path: "src/checkout/payments.ts",
        body: "Check the total first.",
        subject: "FILE",
      },
    ],
  ]);
});

test("a comment GitHub answers no thread for is refused, not taken as added", async () => {
  gitHubTaking(NO_REVIEW, {
    addPullRequestReviewThread: { data: { addPullRequestReviewThread: { thread: null } } },
  });
  const refused = await errorOf(await writeToGitHub(REPO, 7, ADD, env()));
  assert.equal(refused?.[0], 422);
  assert.match(refused?.[1] ?? "", /src\/checkout\/payments\.ts/);
});

test("a refused write to the unsent review answers GitHub's own words", async () => {
  gitHubTaking(reviewOf([{ id: "PRRC_3" }]), {
    addPullRequestReviewThread: {
      data: { addPullRequestReviewThread: null },
      errors: [
        {
          type: "UNPROCESSABLE",
          path: ["addPullRequestReviewThread"],
          message: "Line must be part of the diff",
        },
      ],
    },
    updatePullRequestReviewComment: {
      data: null,
      errors: [{ type: "VALIDATION", message: "Body cannot be blank." }],
    },
    deletePullRequestReviewComment: {
      data: { deletePullRequestReviewComment: null },
      errors: [
        { type: "FORBIDDEN", message: "octocat does not have permission to delete this comment." },
      ],
    },
  });
  assert.deepEqual(await errorOf(await writeToGitHub(REPO, 7, ADD, env())), [
    422,
    "Line must be part of the diff",
  ]);
  const edit = { kind: "pending_edit", comment: "PRRC_3", body: "Check the total." };
  assert.deepEqual(await errorOf(await writeToGitHub(REPO, 7, edit, env())), [
    422,
    "Body cannot be blank.",
  ]);
  const remove = { kind: "pending_delete", comment: "PRRC_3" };
  assert.deepEqual(await errorOf(await writeToGitHub(REPO, 7, remove, env())), [
    403,
    "octocat does not have permission to delete this comment.",
  ]);
});

test("a write GitHub could not be asked answers as before, with no status in its words", async () => {
  stubFetch(() => new Response("bad gateway", { status: 502 }));
  const refused = await errorOf(await writeToGitHub(REPO, 7, ADD, env()));
  assert.equal(refused?.[0], 502);
  assert.doesNotMatch(refused?.[1] ?? "", /\d{3}/);
});

test("a posted thread's reply, resolve and viewed mark answer a GraphQL refusal as they always have", async () => {
  gitHub(() => ({ data: null, errors: [{ type: "FORBIDDEN", message: "Not yours to resolve." }] }));
  const resolve = { kind: "resolve", thread: "PRRT_1", resolved: true };
  const refused = await errorOf(await writeToGitHub(REPO, 7, resolve, env()));
  assert.equal(refused?.[0], 502);
  assert.doesNotMatch(refused?.[1] ?? "", /Not yours/);
});

const HELD = {
  id: "PRRC_3",
  path: "src/checkout/payments.ts",
  line: 40,
  body: "This check went missing.",
};
const EDIT = { kind: "pending_edit", comment: "PRRC_3", body: "Check the total." };
const DELETE = { kind: "pending_delete", comment: "PRRC_3" };

test("an edit and a delete of a comment in the unsent review name the comment", async () => {
  const calls = gitHubTaking(reviewOf([HELD]));
  assert.equal(await writeToGitHub(REPO, 7, EDIT, env()), null);
  assert.equal(await writeToGitHub(REPO, 7, DELETE, env()), null);
  assert.deepEqual(sent(calls), [
    ["repository", { owner: "acme", name: "app", number: 7 }],
    ["updatePullRequestReviewComment", { comment: "PRRC_3", body: "Check the total." }],
    ["repository", { owner: "acme", name: "app", number: 7 }],
    ["deletePullRequestReviewComment", { comment: "PRRC_3" }],
  ]);
  assert.ok(calls.every((call) => call.token === "owner"));
});

test("a comment that is not in the unsent review is never edited or deleted: nothing is sent", async () => {
  const refusal = [409, "That comment is no longer in your unsent review. Refresh the PR."];
  // A posted comment, or one GitHub has not got: the unsent review holds another. Then no unsent review at all.
  for (const found of [reviewOf([{ ...HELD, id: "PRRC_9" }]), reviewOf(), NO_REVIEW]) {
    const calls = gitHubTaking(found);
    assert.deepEqual(await errorOf(await writeToGitHub(REPO, 7, EDIT, env())), refusal);
    assert.deepEqual(await errorOf(await writeToGitHub(REPO, 7, DELETE, env())), refusal);
    assert.deepEqual(
      sent(calls).map(([root]) => root),
      ["repository", "repository"],
    );
  }
});

test("a comment in another person's unsent review is not the viewer's to change", async () => {
  const found = reviewOf([HELD]);
  found.repository.pullRequest.reviews.nodes[0]!.viewerDidAuthor = false;
  const calls = gitHubTaking(found);
  assert.equal((await errorOf(await writeToGitHub(REPO, 7, DELETE, env())))?.[0], 409);
  assert.equal(sent(calls).length, 1);
});

test("a comment GitHub no longer has when the edit arrives is not found", async () => {
  gitHubTaking(reviewOf([HELD]), {
    updatePullRequestReviewComment: {
      data: { updatePullRequestReviewComment: null },
      errors: [{ type: "NOT_FOUND", message: "Could not resolve to a node." }],
    },
  });
  assert.equal((await errorOf(await writeToGitHub(REPO, 7, EDIT, env())))?.[0], 404);
});

const REPLY = { kind: "pending_reply", thread: "PRRT_1", body: "It is." };

test("a reply waits in the unsent review, which is found as the owner", async () => {
  const calls = gitHubTaking(reviewOf());
  assert.equal(await writeToGitHub(REPO, 7, REPLY, env()), null);
  assert.deepEqual(sent(calls), [
    ["repository", { owner: "acme", name: "app", number: 7 }],
    ["addPullRequestReviewThreadReply", { review: "PRR_2", thread: "PRRT_1", body: "It is." }],
  ]);
  // The read token's account does not see the owner's unsent review.
  assert.deepEqual(
    calls.map((call) => call.token),
    ["owner", "owner"],
  );
});

test("a reply with no review started starts one unsent, so the reply is not posted at once", async () => {
  const calls = gitHubTaking();
  assert.equal(await writeToGitHub(REPO, 7, REPLY, env()), null);
  assert.deepEqual(sent(calls).slice(1), [
    ["addPullRequestReview", { pr: "PR_kwDOAcme7" }],
    ["addPullRequestReviewThreadReply", { review: "PRR_3", thread: "PRRT_1", body: "It is." }],
  ]);
});

test("another person's review is never taken for the viewer's own", async () => {
  const found = reviewOf();
  found.repository.pullRequest.reviews.nodes[0]!.viewerDidAuthor = false;
  const calls = gitHubTaking(found);
  assert.equal(await writeToGitHub(REPO, 7, { kind: "pending_discard" }, env()), null);
  assert.deepEqual(sent(calls).slice(1), []);
});

test("sending the unsent review sends that review, with words only when there are some", async () => {
  const calls = gitHubTaking(reviewOf());
  const submit = { kind: "pending_submit", event: "REQUEST_CHANGES", body: "Two things." };
  assert.equal(await writeToGitHub(REPO, 7, submit, env()), null);
  assert.equal(
    await writeToGitHub(REPO, 7, { ...submit, event: "COMMENT", body: "" }, env()),
    null,
  );
  assert.deepEqual(
    sent(calls).filter(([root]) => root !== "repository"),
    [
      [
        "submitPullRequestReview",
        { review: "PRR_2", event: "REQUEST_CHANGES", body: "Two things." },
      ],
      // No `body`: GitHub is not told to replace the words the review has.
      ["submitPullRequestReview", { review: "PRR_2", event: "COMMENT" }],
    ],
  );
});

test("sending with no review started posts a review of these words alone", async () => {
  const calls = gitHubTaking();
  const submit = { kind: "pending_submit", event: "APPROVE", body: "" };
  assert.equal(await writeToGitHub(REPO, 7, submit, env()), null);
  assert.equal(await writeToGitHub(REPO, 7, { ...submit, body: "Ship it." }, env()), null);
  assert.deepEqual(
    sent(calls).filter(([root]) => root !== "repository"),
    [
      ["addPullRequestReview", { pr: "PR_kwDOAcme7", event: "APPROVE" }],
      ["addPullRequestReview", { pr: "PR_kwDOAcme7", event: "APPROVE", body: "Ship it." }],
    ],
  );
});

test("discarding deletes the unsent review, and none there counts as done", async () => {
  const calls = gitHubTaking(reviewOf());
  assert.equal(await writeToGitHub(REPO, 7, { kind: "pending_discard" }, env()), null);
  assert.deepEqual(sent(calls).slice(1), [["deletePullRequestReview", { review: "PRR_2" }]]);
  const none = gitHubTaking();
  assert.equal(await writeToGitHub(REPO, 7, { kind: "pending_discard" }, env()), null);
  assert.deepEqual(
    sent(none).map(([root]) => root),
    ["repository"],
  );
});

test("a PR GitHub has not got refuses a write to its unsent review", async () => {
  gitHubTaking({ repository: null });
  const refused = await errorOf(await writeToGitHub(REPO, 7, { kind: "pending_discard" }, env()));
  assert.equal(refused?.[0], 404);
});

// --- A whole review posted while one is unsent ---------------------------------------------------------------------

const REVIEW = {
  kind: "review",
  event: "COMMENT",
  body: "Two things.",
  commit: "504754b2bc3ce5db892dde980e4bc83b60ff7a68",
  comments: [
    { path: "src/checkout/payments.ts", line: 12, side: "RIGHT", body: "Check the total first." },
    { path: "src/checkout/cart.ts", line: 3, side: "LEFT", body: "This check went missing." },
  ],
};
const ONE_PENDING = {
  message: "Unprocessable Entity",
  errors: ["User can only have one pending review per pull request"],
};

/** GitHub refusing the review's POST with `refusal`, and answering GraphQL as `gitHubTaking` does. */
function gitHubRefusingReview(
  refusal: unknown,
  found: unknown = reviewOf(),
  answers: Record<string, unknown> = {},
): Asked[] {
  return stubFetch((asked) => {
    if (!asked.graphql) {
      return Response.json(refusal, { status: 422 });
    }
    const root = rootOf(asked.graphql);
    if (root === "repository") {
      return Response.json({ data: found });
    }
    return Response.json(root in answers ? answers[root] : { data: { [root]: TOOK[root] } });
  });
}

test("a review posted while one is unsent joins it: its comments are added, then that review is sent", async () => {
  const calls = gitHubRefusingReview(ONE_PENDING);
  assert.equal(await writeToGitHub(REPO, 7, REVIEW, env()), null);
  assert.deepEqual(
    [calls[0]?.method, calls[0]?.url],
    ["POST", "https://api.github.com/repos/acme/app/pulls/7/reviews"],
  );
  const thread = (path: string, line: number, side: string, body: string) => [
    "addPullRequestReviewThread",
    { pr: "PR_kwDOAcme7", path, body, line, side, subject: "LINE" },
  ];
  assert.deepEqual(sent(calls), [
    ["repository", { owner: "acme", name: "app", number: 7 }],
    thread("src/checkout/payments.ts", 12, "RIGHT", "Check the total first."),
    thread("src/checkout/cart.ts", 3, "LEFT", "This check went missing."),
    ["submitPullRequestReview", { review: "PRR_2", event: "COMMENT", body: "Two things." }],
  ]);
  assert.ok(calls.every((call) => call.token === "owner"));
});

test("a copy of that review sent again does not add a comment the unsent review already holds", async () => {
  const held = { path: "src/checkout/payments.ts", line: 12, body: "Check the total first." };
  const calls = gitHubRefusingReview(ONE_PENDING, reviewOf([held]));
  assert.equal(await writeToGitHub(REPO, 7, REVIEW, env()), null);
  assert.deepEqual(
    sent(calls).map(([root, variables]) => [root, (variables as { path?: string }).path]),
    [
      ["repository", undefined],
      ["addPullRequestReviewThread", "src/checkout/cart.ts"],
      ["submitPullRequestReview", undefined],
    ],
  );
});

test("a review that joins the unsent one and fails part way says why, and is not sent", async () => {
  const calls = gitHubRefusingReview(ONE_PENDING, reviewOf(), {
    addPullRequestReviewThread: {
      data: { addPullRequestReviewThread: null },
      errors: [{ type: "UNPROCESSABLE", message: "Line must be part of the diff" }],
    },
  });
  assert.deepEqual(await errorOf(await writeToGitHub(REPO, 7, REVIEW, env())), [
    422,
    "Line must be part of the diff",
  ]);
  assert.deepEqual(
    sent(calls).map(([root]) => root),
    ["repository", "addPullRequestReviewThread"],
  );
});

test("any other refusal of a review answers GitHub's words, and nothing more is sent", async () => {
  const calls = gitHubRefusingReview({
    message: "Unprocessable Entity",
    errors: ["Can not approve your own pull request"],
  });
  assert.deepEqual(await errorOf(await writeToGitHub(REPO, 7, REVIEW, env())), [
    422,
    "Unprocessable Entity: Can not approve your own pull request",
  ]);
  assert.equal(calls.length, 1);
});

test("a review refused for an unsent one that has gone since answers GitHub's refusal", async () => {
  gitHubRefusingReview(ONE_PENDING, NO_REVIEW);
  assert.deepEqual(await errorOf(await writeToGitHub(REPO, 7, REVIEW, env())), [
    422,
    "Unprocessable Entity: User can only have one pending review per pull request",
  ]);
});
