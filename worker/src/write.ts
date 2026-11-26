import { type Env, githubLogin } from "./env";
import { getFromGitHub, graphql, GraphqlRefusal, postToGitHub, sendToGitHub } from "./github";
import { repoParts, type RepoFullName } from "./ids";
import {
  gitHubReason,
  parseWrite,
  type PendingWrite,
  refusalWords,
  type ReviewComment,
  toggleTask,
  type Write,
} from "./write-input";

const RESOLVE = `mutation($thread: ID!) { resolveReviewThread(input: { threadId: $thread }) { thread { id } } }`;
const UNRESOLVE = `mutation($thread: ID!) { unresolveReviewThread(input: { threadId: $thread }) { thread { id } } }`;
const REPLY = `mutation($thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $thread, body: $body }) { comment { id } }
}`;

const VIEWED = `mutation($pr: ID!, $path: String!) {
  markFileAsViewed(input: { pullRequestId: $pr, path: $path }) { pullRequest { id } }
}`;
const NOT_VIEWED = `mutation($pr: ID!, $path: String!) {
  unmarkFileAsViewed(input: { pullRequestId: $pr, path: $path }) { pullRequest { id } }
}`;

/**
 * The viewer's review not yet sent on a PR, with the PR's own id. `viewerDidAuthor` is asked for, so the call goes as the
 * owner (`readsAsAnyone`): no other account sees the review.
 */
const PENDING_REVIEW = `query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    id
    reviews(states: [PENDING], first: 1) { nodes {
      id viewerDidAuthor comments(first: 100) { nodes { id path line body } }
    } }
  } }
}`;
/** With no review id, GitHub adds the thread to the viewer's unsent review, and starts one when there is none. */
const ADD_THREAD = `mutation(
  $pr: ID!, $path: String!, $body: String!, $line: Int, $side: DiffSide, $subject: PullRequestReviewThreadSubjectType
) {
  addPullRequestReviewThread(input: {
    pullRequestId: $pr, path: $path, body: $body, line: $line, side: $side, subjectType: $subject
  }) { thread { id } }
}`;
/** Without an event the review stays unsent, and with the PR's id alone it is empty; with an event it is sent at once. */
const ADD_REVIEW = `mutation($pr: ID!, $event: PullRequestReviewEvent, $body: String) {
  addPullRequestReview(input: { pullRequestId: $pr, event: $event, body: $body }) { pullRequestReview { id } }
}`;
/** A reply that names the unsent review belongs to it. Without one GitHub may post the reply at once. */
const REPLY_PENDING = `mutation($review: ID!, $thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewId: $review, pullRequestReviewThreadId: $thread, body: $body
  }) { comment { id } }
}`;
const EDIT_COMMENT = `mutation($comment: ID!, $body: String!) {
  updatePullRequestReviewComment(input: { pullRequestReviewCommentId: $comment, body: $body }) {
    pullRequestReviewComment { id }
  }
}`;
const DELETE_COMMENT = `mutation($comment: ID!) {
  deletePullRequestReviewComment(input: { id: $comment }) { clientMutationId }
}`;
const SUBMIT_REVIEW = `mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: { pullRequestReviewId: $review, event: $event, body: $body }) {
    pullRequestReview { id }
  }
}`;
const DELETE_REVIEW = `mutation($review: ID!) {
  deletePullRequestReview(input: { pullRequestReviewId: $review }) { clientMutationId }
}`;

/** GitHub's words when a review is posted while the viewer has one not yet sent. */
const ONE_PENDING_REVIEW = "User can only have one pending review per pull request";

/** A write GitHub did not take, as the phone is told: what happened, under the status it reads. */
class Refused extends Error {
  readonly status: number;

  constructor(status: number, words: string) {
    super(words);
    this.name = "Refused";
    this.status = status;
  }
}

/** One mutation as the owner. What GitHub can't find is a null with no failure, and that is refused here. */
async function mutate(query: string, variables: object, env: Env): Promise<unknown> {
  const result = await graphql<Record<string, unknown>>(query, variables, env);
  const [answer] = Object.values(result);
  if (answer === null || answer === undefined) {
    throw new Refused(404, "GitHub can't find that.");
  }
  return answer;
}

interface PendingComment {
  id: string;
  path: string;
  line: number | null;
  body: string;
}

/**
 * A PR's own id, and the viewer's unsent review on it with the comments it holds; null with none started. The comments
 * are its first 100, as many as the detail reads (`VIEWER_FIELDS`).
 */
interface Pending {
  pullRequest: string;
  review: { id: string; comments: PendingComment[] } | null;
}

async function pendingOf(repo: RepoFullName, number: number, env: Env): Promise<Pending> {
  const { owner, name } = repoParts(repo);
  const data = await graphql<{
    repository: {
      pullRequest: {
        id: string;
        reviews: {
          nodes: {
            id: string;
            viewerDidAuthor: boolean;
            comments: { nodes: PendingComment[] };
          }[];
        };
      } | null;
    } | null;
  }>(PENDING_REVIEW, { owner, name, number }, env);
  const pullRequest = data.repository?.pullRequest;
  if (!pullRequest) {
    throw new Refused(404, refusalWords(404));
  }
  const review = pullRequest.reviews.nodes.find((one) => one.viewerDidAuthor);
  return {
    pullRequest: pullRequest.id,
    review: review ? { id: review.id, comments: review.comments.nodes } : null,
  };
}

/**
 * A thread on a line, or on the whole file. GitHub answers no thread, and no failure, for a line outside the diff's
 * hunks (an unchanged line of a changed file among them) and for a file the diff has not got.
 */
async function addThread(
  pullRequest: string,
  comment: Pick<ReviewComment, "path" | "body"> & {
    line: number | null;
    side: "LEFT" | "RIGHT";
    file?: boolean;
  },
  env: Env,
): Promise<void> {
  const place = comment.file
    ? { subject: "FILE" }
    : { line: comment.line, side: comment.side, subject: "LINE" };
  const added = (await mutate(
    ADD_THREAD,
    { pr: pullRequest, path: comment.path, body: comment.body, ...place },
    env,
  )) as { thread: { id: string } | null };
  if (!added.thread) {
    throw new Refused(
      422,
      `GitHub didn't take the comment on ${comment.path}. Its line may no longer be in the diff.`,
    );
  }
}

/** A review's words as a mutation takes them: none are left out, never sent as empty ones. */
const wordsOf = (body: string) => (body === "" ? {} : { body });

/** Sends the unsent review. With no words given, the mutation names none, and the review keeps its own. */
function submit(review: string, event: string, body: string, env: Env): Promise<unknown> {
  return mutate(SUBMIT_REVIEW, { review, event, ...wordsOf(body) }, env);
}

/** An unsent review with nothing in it yet, for a reply to wait in. */
async function startReview(pullRequest: string, env: Env): Promise<{ id: string }> {
  const added = (await mutate(ADD_REVIEW, { pr: pullRequest }, env)) as {
    pullRequestReview: { id: string } | null;
  };
  if (!added.pullRequestReview) {
    throw new Refused(404, "GitHub can't find that.");
  }
  return added.pullRequestReview;
}

async function sendPending(
  write: PendingWrite,
  repo: RepoFullName,
  number: number,
  env: Env,
): Promise<void> {
  if (write.kind === "pending_add") {
    await addThread(write.pullRequest, write, env);
    return;
  }
  const { pullRequest, review } = await pendingOf(repo, number, env);
  if (write.kind === "pending_edit" || write.kind === "pending_delete") {
    // GitHub would change any review comment the person wrote. These change one not yet sent, on this PR, and no other:
    // a comment sent since, or one past the first 100 read here, is refused and nothing is sent.
    if (!review?.comments.some((comment) => comment.id === write.comment)) {
      throw new Refused(409, "That comment is no longer in your unsent review. Refresh the PR.");
    }
    await (write.kind === "pending_edit"
      ? mutate(EDIT_COMMENT, { comment: write.comment, body: write.body }, env)
      : mutate(DELETE_COMMENT, { comment: write.comment }, env));
  } else if (write.kind === "pending_reply") {
    const started = review ?? (await startReview(pullRequest, env));
    await mutate(
      REPLY_PENDING,
      { review: started.id, thread: write.thread, body: write.body },
      env,
    );
  } else if (write.kind === "pending_discard") {
    if (review) {
      await mutate(DELETE_REVIEW, { review: review.id }, env);
    }
  } else if (review) {
    await submit(review.id, write.event, write.body, env);
  } else {
    await mutate(ADD_REVIEW, { pr: pullRequest, event: write.event, ...wordsOf(write.body) }, env);
  }
}

/**
 * A review GitHub refused because the viewer has one not yet sent: its comments join that review, and the review is
 * sent with this one's event and words. A comment already there, from a copy of this write that failed part way, is not
 * added twice. False when the unsent review has gone since.
 */
async function foldIntoPending(
  write: Extract<Write, { kind: "review" }>,
  repo: RepoFullName,
  number: number,
  env: Env,
): Promise<boolean> {
  const { pullRequest, review } = await pendingOf(repo, number, env);
  if (!review) {
    return false;
  }
  for (const comment of write.comments) {
    const isThere = review.comments.some(
      (one) => one.path === comment.path && one.line === comment.line && one.body === comment.body,
    );
    if (!isThere) {
      await addThread(pullRequest, comment, env);
    }
  }
  await submit(review.id, write.event, write.body, env);
  return true;
}

const GRAPHQL_STATUS: Record<string, number> = { FORBIDDEN: 403, NOT_FOUND: 404 };

/** The answer for a write on the unsent review that failed: GitHub's own words where it gave them. */
function refusalOf(error: unknown): Response {
  if (error instanceof Refused) {
    return Response.json({ error: error.message }, { status: error.status });
  }
  if (error instanceof GraphqlRefusal && error.words !== "") {
    return Response.json(
      { error: error.words },
      { status: GRAPHQL_STATUS[error.type ?? ""] ?? 422 },
    );
  }
  console.error("write: GitHub GraphQL failed", error);
  return Response.json({ error: refusalWords(502) }, { status: 502 });
}

function isPending(write: Write): write is PendingWrite {
  return write.kind.startsWith("pending_");
}

function mutationOf(write: Write): { query: string; variables: object } | null {
  switch (write.kind) {
    case "reply":
      return { query: REPLY, variables: { thread: write.thread, body: write.body } };
    case "resolve":
      return { query: write.resolved ? RESOLVE : UNRESOLVE, variables: { thread: write.thread } };
    case "viewed":
      return {
        query: write.viewed ? VIEWED : NOT_VIEWED,
        variables: { pr: write.pullRequest, path: write.path },
      };
    default:
      return null;
  }
}

/** Reads the body now and changes one task, so a tap can't undo an edit made since the phone last synced. */
async function setTask(
  path: string,
  index: number,
  checked: boolean,
  task: string | null,
  env: Env,
): Promise<Response> {
  const current = await getFromGitHub(path, env);
  if (!current.ok) {
    return current;
  }
  const { body } = (await current.json()) as { body: string | null };
  const next = toggleTask(body ?? "", index, checked, task);
  return next === null
    ? Response.json({ message: "That checkbox has moved. Refresh the PR." }, { status: 409 })
    : sendToGitHub("PATCH", path, { body: next }, env);
}

/**
 * With `base`, the description as the phone had it when Jai started: a late copy of an edit must not overwrite a newer
 * one. The same words already there count as done.
 */
async function editBody(
  path: string,
  body: string,
  base: string | null,
  env: Env,
): Promise<Response> {
  if (base !== null) {
    const current = await getFromGitHub(path, env);
    if (!current.ok) {
      return current;
    }
    const now = ((await current.json()) as { body: string | null }).body ?? "";
    if (now !== base && now !== body) {
      return Response.json(
        { message: "The description changed since you started editing. Refresh the PR." },
        { status: 409 },
      );
    }
  }
  return sendToGitHub("PATCH", path, { body }, env);
}

async function sendRest(
  write: Exclude<Write, PendingWrite>,
  repo: string,
  number: number,
  env: Env,
): Promise<Response> {
  const pull = `/repos/${repo}/pulls/${number}`;
  switch (write.kind) {
    case "comment":
      return postToGitHub(`/repos/${repo}/issues/${number}/comments`, { body: write.body }, env);
    case "review":
      return postToGitHub(
        `${pull}/reviews`,
        { event: write.event, body: write.body, commit_id: write.commit, comments: write.comments },
        env,
      );
    case "line":
      return postToGitHub(
        `${pull}/comments`,
        {
          body: write.body,
          commit_id: write.commit,
          path: write.path,
          line: write.line,
          side: write.side,
        },
        env,
      );
    case "update_branch":
      return sendToGitHub("PUT", `${pull}/update-branch`, { expected_head_sha: write.commit }, env);
    case "remove_request":
      return sendToGitHub(
        "DELETE",
        `${pull}/requested_reviewers`,
        { reviewers: [await githubLogin(env)] },
        env,
      );
    case "checkbox":
      return setTask(pull, write.index, write.checked, write.task, env);
    case "edit_body":
      return editBody(pull, write.body, write.base, env);
    case "merge":
      return sendToGitHub(
        "PUT",
        `${pull}/merge`,
        { merge_method: write.method, sha: write.commit },
        env,
      );
    default:
      return Response.json({ message: "That goes through GraphQL." }, { status: 400 });
  }
}

/** Null when GitHub took it. Otherwise the answer for the phone, with GitHub's own words: it decides what is allowed. */
export async function writeToGitHub(
  repo: RepoFullName,
  number: number,
  input: unknown,
  env: Env,
): Promise<Response | null> {
  const write = parseWrite(input);
  if (!write) {
    return Response.json({ error: "That is not something the viewer can post." }, { status: 400 });
  }
  if (isPending(write)) {
    return sendPending(write, repo, number, env).then(() => null, refusalOf);
  }
  const mutation = mutationOf(write);
  if (mutation) {
    try {
      const result = await graphql<Record<string, unknown>>(
        mutation.query,
        mutation.variables,
        env,
      );
      // What GitHub can't find is a null here with no failure, and a read would treat that as an answer.
      const tookEffect = Object.values(result).every((value) => value !== null);
      return tookEffect
        ? null
        : Response.json({ error: "GitHub can't find that." }, { status: 404 });
    } catch (error) {
      console.error("write: GitHub GraphQL failed", error);
      return Response.json({ error: refusalWords(502) }, { status: 502 });
    }
  }
  const response = await sendRest(write, repo, number, env);
  if (response.ok) {
    return null;
  }
  const answer = await response.json().catch(() => null);
  const reason = gitHubReason(answer);
  if (write.kind === "review" && response.status === 422 && reason.includes(ONE_PENDING_REVIEW)) {
    const folded = await foldIntoPending(write, repo, number, env).catch(refusalOf);
    if (folded !== false) {
      return folded === true ? null : folded;
    }
  }
  return Response.json(
    { error: reason || refusalWords(response.status) },
    { status: response.status },
  );
}
