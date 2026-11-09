import { type Env, githubLogin } from "./env";
import { getFromGitHub, graphql, postToGitHub, sendToGitHub } from "./github";
import { gitHubReason, parseWrite, refusalWords, toggleTask, type Write } from "./write-input";

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

function mutationOf(write: Write): { query: string; variables: object } | null {
  switch (write.kind) {
    case "reply": return { query: REPLY, variables: { thread: write.thread, body: write.body } };
    case "resolve": return { query: write.resolved ? RESOLVE : UNRESOLVE, variables: { thread: write.thread } };
    case "viewed":
      return { query: write.viewed ? VIEWED : NOT_VIEWED, variables: { pr: write.pullRequest, path: write.path } };
    default: return null;
  }
}

/** Reads the body now and changes one task, so a tap can't undo an edit made since the phone last synced. */
async function setTask(path: string, index: number, checked: boolean, task: string | null, env: Env): Promise<Response> {
  const current = await getFromGitHub(path, env);
  if (!current.ok) {
    return current;
  }
  const { body } = await current.json() as { body: string | null };
  const next = toggleTask(body ?? "", index, checked, task);
  return next === null
    ? Response.json({ message: "That checkbox has moved. Refresh the PR." }, { status: 409 })
    : sendToGitHub("PATCH", path, { body: next }, env);
}

/**
 * With `base`, the description as the phone had it when Jai started: a late copy of an edit must not overwrite a newer
 * one. The same words already there count as done.
 */
async function editBody(path: string, body: string, base: string | null, env: Env): Promise<Response> {
  if (base !== null) {
    const current = await getFromGitHub(path, env);
    if (!current.ok) {
      return current;
    }
    const now = ((await current.json()) as { body: string | null }).body ?? "";
    if (now !== base && now !== body) {
      return Response.json({ message: "The description changed since you started editing. Refresh the PR." },
        { status: 409 });
    }
  }
  return sendToGitHub("PATCH", path, { body }, env);
}

async function sendRest(write: Write, repo: string, number: number, env: Env): Promise<Response> {
  const pull = `/repos/${repo}/pulls/${number}`;
  switch (write.kind) {
    case "comment": return postToGitHub(`/repos/${repo}/issues/${number}/comments`, { body: write.body }, env);
    case "review":
      return postToGitHub(`${pull}/reviews`,
        { event: write.event, body: write.body, commit_id: write.commit, comments: write.comments }, env);
    case "line":
      return postToGitHub(`${pull}/comments`,
        { body: write.body, commit_id: write.commit, path: write.path, line: write.line, side: write.side }, env);
    case "update_branch": return sendToGitHub("PUT", `${pull}/update-branch`, { expected_head_sha: write.commit }, env);
    case "remove_request":
      return sendToGitHub("DELETE", `${pull}/requested_reviewers`, { reviewers: [await githubLogin(env)] }, env);
    case "checkbox": return setTask(pull, write.index, write.checked, write.task, env);
    case "edit_body": return editBody(pull, write.body, write.base, env);
    case "merge": return sendToGitHub("PUT", `${pull}/merge`, { merge_method: write.method, sha: write.commit }, env);
    default: return Response.json({ message: "That goes through GraphQL." }, { status: 400 });
  }
}

/** Null when GitHub took it. Otherwise the answer for the phone, with GitHub's own words: it decides what is allowed. */
export async function writeToGitHub(repo: string, number: number, input: unknown, env: Env): Promise<Response | null> {
  const write = parseWrite(input);
  if (!write) {
    return Response.json({ error: "That is not something the viewer can post." }, { status: 400 });
  }
  const mutation = mutationOf(write);
  if (mutation) {
    try {
      const result = await graphql<Record<string, unknown>>(mutation.query, mutation.variables, env);
      // What GitHub can't find is a null here with no failure, and a read would treat that as an answer.
      const tookEffect = Object.values(result).every((value) => value !== null);
      return tookEffect ? null : Response.json({ error: "GitHub can't find that." }, { status: 404 });
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
  return Response.json({ error: reason || refusalWords(response.status) }, { status: response.status });
}

