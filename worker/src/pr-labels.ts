/**
 * A PR's labels (docs/api.md, "Labels"): `GET /prs/{owner}/{repo}/{n}/labels` lists the labels the repo has and says
 * whether the person may change the PR's, and the `label_add` and `label_remove` writes put one on and take one off.
 * Nothing is kept: a label list changes on GitHub with no word to this Worker.
 */
import type { Env } from "./env.ts";
import { getFromGitHub, graphql, sendToGitHub } from "./github.ts";
import { repoParts, type RepoFullName } from "./ids.ts";

const PAGE = 100;
/** A repo with more labels is served its first this many, as GitHub lists them. */
export const MAX_REPO_LABELS = 500;
export interface RepoLabel {
  name: string;
  /** Six hex digits, as the detail's labels have it. */
  color: string;
  description: string | null;
}

/**
 * `viewerCanLabel` is GitHub's own answer ("Indicates if the viewer can edit labels for this object"). It names the
 * viewer, so the call goes as the owner (`readsAsAnyone`), never as the read token's account.
 */
const CAN_LABEL = `query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) { viewerCanLabel } }
}`;

function errorAnswer(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}

function labelOf(raw: unknown): RepoLabel | null {
  const { name, color, description } = (raw ?? {}) as Record<string, unknown>;
  if (typeof name !== "string" || name === "") {
    return null;
  }
  return {
    name,
    color: typeof color === "string" ? color : "",
    description: typeof description === "string" && description !== "" ? description : null,
  };
}

/** Every label of the repo, up to `MAX_REPO_LABELS`, by name whatever its case; GitHub's answer when it refuses. */
async function repoLabels(repo: RepoFullName, env: Env): Promise<RepoLabel[] | Response> {
  const labels: RepoLabel[] = [];
  for (let page = 1; labels.length < MAX_REPO_LABELS; page += 1) {
    const response = await getFromGitHub(
      `/repos/${repo}/labels?per_page=${PAGE}&page=${page}`,
      env,
    );
    if (!response.ok) {
      return response;
    }
    const listed: unknown = await response.json().catch(() => null);
    const rows = Array.isArray(listed) ? listed : [];
    labels.push(...rows.map(labelOf).filter((label): label is RepoLabel => label !== null));
    if (rows.length < PAGE) {
      break;
    }
  }
  return labels
    .slice(0, MAX_REPO_LABELS)
    .sort((one, other) => one.name.localeCompare(other.name, "en", { sensitivity: "base" }));
}

/** Whether the person may label this PR; null when GitHub has no such PR for them. */
async function canLabel(repo: RepoFullName, number: number, env: Env): Promise<boolean | null> {
  const { owner, name } = repoParts(repo);
  const data = await graphql<{
    repository: { pullRequest: { viewerCanLabel: boolean } | null } | null;
  }>(CAN_LABEL, { owner, name, number }, env);
  return data.repository?.pullRequest?.viewerCanLabel ?? null;
}

export async function labelsRoute(repo: RepoFullName, number: number, env: Env): Promise<Response> {
  const notFound = () => errorAnswer(404, "not_found", "no such pull request");
  let read: [RepoLabel[] | Response, boolean | null];
  try {
    read = await Promise.all([repoLabels(repo, env), canLabel(repo, number, env)]);
  } catch (error) {
    console.error("labels failed", error);
    return errorAnswer(502, "github_unavailable", "GitHub could not be asked");
  }
  const [labels, canEdit] = read;
  if (labels instanceof Response) {
    return labels.status === 404 ? notFound() : labels;
  }
  return canEdit === null
    ? notFound()
    : Response.json({ labels, canEdit }, { headers: { "Cache-Control": "no-store" } });
}

/**
 * Puts a label the repo already has on the PR. GitHub's own call makes a label that does not exist, for anyone who can
 * push, so the repo is asked for this one first: it finds a name whatever its case, and its own spelling is sent.
 */
export async function addLabel(
  repo: string,
  number: number,
  name: string,
  env: Env,
): Promise<Response> {
  const found = await getFromGitHub(`/repos/${repo}/labels/${encodeURIComponent(name)}`, env);
  if (!found.ok && found.status !== 404) {
    return found;
  }
  const label = found.ok ? labelOf(await found.json().catch(() => null)) : null;
  if (!label || label.name.toLowerCase() !== name.toLowerCase()) {
    return Response.json({ message: `This repo has no label named "${name}".` }, { status: 422 });
  }
  return sendToGitHub(
    "POST",
    `/repos/${repo}/issues/${number}/labels`,
    { labels: [label.name] },
    env,
  );
}

/** GitHub's words for a label that is not on the PR: it is already off, which is what was asked. */
const NOT_ON_PR = "Label does not exist";

export async function removeLabel(
  repo: string,
  number: number,
  name: string,
  env: Env,
): Promise<Response> {
  const response = await sendToGitHub(
    "DELETE",
    `/repos/${repo}/issues/${number}/labels/${encodeURIComponent(name)}`,
    {},
    env,
  );
  if (response.status !== 404) {
    return response;
  }
  const answer = (await response.json().catch(() => null)) as { message?: unknown } | null;
  return answer?.message === NOT_ON_PR
    ? new Response(null, { status: 204 })
    : Response.json(answer, { status: 404 });
}
