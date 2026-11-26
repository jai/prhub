/**
 * `GET /prs/{owner}/{repo}/{n}/file?path=…&head=…` (docs/api.md, "A file at the head"): one file's text at the PR's head
 * commit, so the app can show the unchanged lines GitHub's diff leaves out. R2, then GitHub, as the diff: a file at a
 * commit never changes, so a copy is good for ever, and it is kept under the asker's own prefix (`scopedKey`).
 */
import { type Env, scopedKey } from "./env.ts";
import { fetchFile, getFromGitHub } from "./github.ts";
import { parseSha, type Sha } from "./ids.ts";
import { sha256Hex } from "./pairing.ts";

/** A file past this is not served: the app holds it whole, beside the diff. */
export const MAX_FILE_BYTES = 1_048_576;
const MAX_PATH_LENGTH = 1_024;
/** A NUL this early says the file is not text, as git tells. */
const BINARY_SCAN_BYTES = 8_192;
const CONTENT_TYPE = "text/plain; charset=utf-8";

/** What the route needs beside `env`; a test passes fakes. */
export interface FileRouteDeps {
  store: Pick<R2Bucket, "get" | "put">;
  /** The head the person's index holds the PR at; null for a PR on none of their lists. */
  indexedHead: () => Promise<string | null>;
  waitUntil: (promise: Promise<unknown>) => void;
}

function errorAnswer(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}

const notFound = () => errorAnswer(404, "not_found", "no such file at that commit");
const tooLarge = () => errorAnswer(413, "too_large", "the file is over 1 MB");

/** A file's path in a repo as a client may send it; null for one that could name anything else. */
export function parseFilePath(raw: unknown): string | null {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > MAX_PATH_LENGTH) {
    return null;
  }
  let hasControl = false;
  for (let at = 0; at < raw.length; at += 1) {
    const code = raw.charCodeAt(at);
    hasControl ||= code < 0x20 || code === 0x7f;
  }
  const isPlain = raw
    .split("/")
    .every((segment) => segment !== "" && segment !== "." && segment !== "..");
  return hasControl || !isPlain ? null : raw;
}

/** Where a file's copy is kept, below `scopedKey`. The path is hashed: a key has a length limit and a path has none. */
export async function fileKey(
  repo: string,
  number: number,
  head: Sha,
  path: string,
): Promise<string> {
  return `${repo}/${number}/${head}/file/${await sha256Hex(path)}`;
}

/**
 * Null when `head` is the PR's head: as the index holds it, else as GitHub has it now (a PR on none of the lists, or a
 * head newer than the index's). Otherwise the answer: any other commit of the repo is not this PR's to read.
 */
async function headProblem(
  repo: string,
  number: number,
  head: Sha,
  env: Env,
  indexedHead: () => Promise<string | null>,
): Promise<Response | null> {
  if ((await indexedHead()) === head) {
    return null;
  }
  const pull = await getFromGitHub(`/repos/${repo}/pulls/${number}`, env);
  if (!pull.ok) {
    return pull.status === 404 ? notFound() : pull;
  }
  const now = (await pull.json().catch(() => null)) as { head?: { sha?: unknown } } | null;
  return parseSha(now?.head?.sha) === head
    ? null
    : errorAnswer(409, "head_moved", "head is not this PR's head commit");
}

/** The body, or null once it is past `max` bytes: the rest is not read. */
async function readUpTo(response: Response, max: number): Promise<Uint8Array | null> {
  const reader = response.body?.getReader();
  const bytes = new Uint8Array(max);
  let size = 0;
  for (;;) {
    const chunk = await reader?.read();
    if (!chunk || chunk.done) {
      return bytes.slice(0, size);
    }
    if (size + chunk.value.byteLength > max) {
      await reader?.cancel();
      return null;
    }
    bytes.set(chunk.value, size);
    size += chunk.value.byteLength;
  }
}

export async function fileRoute(
  repo: string,
  number: number,
  params: URLSearchParams,
  env: Env,
  { store, indexedHead, waitUntil }: FileRouteDeps,
): Promise<Response> {
  const path = parseFilePath(params.get("path"));
  if (!path) {
    return errorAnswer(400, "validation_error", "path must be a file's path in the repo");
  }
  const head = parseSha(params.get("head"));
  if (!head) {
    return errorAnswer(400, "validation_error", "head must be the PR's head commit");
  }
  const key = scopedKey(env, await fileKey(repo, number, head, path));
  const stored = await store.get(key);
  if (stored) {
    return new Response(stored.body, { headers: { "Content-Type": CONTENT_TYPE } });
  }
  const problem = await headProblem(repo, number, head, env, indexedHead);
  if (problem) {
    return problem;
  }
  const response = await fetchFile(repo, path, head, env);
  if (!response.ok) {
    return response.status === 404 ? notFound() : response;
  }
  // A file comes raw. JSON is GitHub describing something else at that path: a directory's listing, a submodule.
  if ((response.headers.get("Content-Type") ?? "").startsWith("application/json")) {
    await response.body?.cancel();
    return notFound();
  }
  if (Number(response.headers.get("Content-Length") ?? 0) > MAX_FILE_BYTES) {
    await response.body?.cancel();
    return tooLarge();
  }
  const bytes = await readUpTo(response, MAX_FILE_BYTES);
  if (!bytes) {
    return tooLarge();
  }
  if (bytes.subarray(0, BINARY_SCAN_BYTES).includes(0)) {
    return errorAnswer(415, "binary_file", "the file is not text");
  }
  waitUntil(store.put(key, bytes, { httpMetadata: { contentType: CONTENT_TYPE } }));
  return new Response(bytes, { headers: { "Content-Type": CONTENT_TYPE } });
}
