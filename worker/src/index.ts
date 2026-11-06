// The PR viewer's Worker: the PRs Jai should look at, each one's diff, and word to the phone when they change.
// docs/plans/pr-viewer.md.
import { statesRoute } from "./pr-states";
import type { ApnsHost } from "./apns";
import { AiJobs, type AiJob, aiKey } from "./ai-jobs";
import { ask, askChat, AskRefused } from "./ask";
import { parseAskInput } from "./ask-chat";
import { askConfigured, deviceConfig, feedbackConfigured } from "./config";
import { aiJobs, type Env, githubLogin, isSet, prIndex } from "./env";
import { fetchDiff, mergedPullRequests, readPullRequests } from "./github";
import {
  feedbackChat, feedbackList, isFeedbackId, parseFeedbackInput, sendFeedback, startFeedback,
} from "./feedback";
import { DEFAULT_CONTEXT } from "./key-lines";
import { detailKey, diffKey, PrIndex } from "./pr-index";
import { deviceSecretOf, normalizePairingCode, sha256Hex } from "./pairing";
import { createAppPage, finishAppCreation } from "./setup";
import { parseDelivery, verifySignature } from "./webhook";
import { writeToGitHub } from "./write";
import { busyAnswer, clientRefOf } from "./write-receipts";

export { AiJobs, PrIndex };

const PULL_REQUEST_PATH = /^\/prs\/([\w.-]+)\/([\w.-]+)\/(\d+)\/(diff|detail|write|key-lines|rewrite|ask)$/;
const VERSION = /^[\w.:-]{1,200}$/;
const COMMIT = /^[0-9a-f]{40}$/;
const MAX_CONTEXT = 2_000;

/** An unset token admits nobody: a self-hosted Worker has no `APP_TOKEN`, and `Bearer ` must not match it. */
function hasToken(request: Request, token: string | undefined): boolean {
  if (!isSet(token)) {
    return false;
  }
  const encoder = new TextEncoder();
  const sent = encoder.encode(request.headers.get("Authorization") ?? "");
  const expected = encoder.encode(`Bearer ${token}`);
  const subtle = crypto.subtle as SubtleCrypto & { timingSafeEqual(a: ArrayBufferView, b: ArrayBufferView): boolean };
  return sent.byteLength === expected.byteLength && subtle.timingSafeEqual(sent, expected);
}

/** Paired fingerprints this isolate has seen lately, so most requests skip asking the index. An unpair lands within it. */
const PAIRED_CACHE_MS = 60_000;
const pairedSeen = new Map<string, number>();

async function isPairedDevice(request: Request, env: Env): Promise<boolean> {
  const secret = deviceSecretOf(request.headers.get("Authorization"));
  if (!secret) {
    return false;
  }
  const fingerprint = await sha256Hex(secret);
  if ((pairedSeen.get(fingerprint) ?? 0) > Date.now()) {
    return true;
  }
  const paired = await prIndex(env).isPaired(fingerprint);
  if (paired) {
    pairedSeen.set(fingerprint, Date.now() + PAIRED_CACHE_MS);
  }
  return paired;
}

/** Jai's app's `APP_TOKEN`, as ever, or the device secret of an app paired with this Worker. */
async function isAuthorized(request: Request, env: Env): Promise<boolean> {
  return hasToken(request, env.APP_TOKEN) || isPairedDevice(request, env);
}

function errorAnswer(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}

/** `POST /device/pair` (docs/api/pr-selfhost.md): a one-time code admits the device secret sent as the bearer. */
async function pairRoute(request: Request, env: Env): Promise<Response> {
  const secret = deviceSecretOf(request.headers.get("Authorization"));
  if (!secret) {
    return errorAnswer(401, "unauthorized", "send the app's device secret as the bearer");
  }
  const body = await request.json().catch(() => null) as { code?: unknown } | null;
  const code = normalizePairingCode(body?.code);
  if (!code) {
    return errorAnswer(400, "validation_error", "code must be the 8-character pairing code");
  }
  const fingerprint = await sha256Hex(secret);
  const record = await prIndex(env).pair(await sha256Hex(code), fingerprint, Date.now());
  if (!record) {
    return errorAnswer(401, "pairing_code_invalid", "unknown, used or expired pairing code");
  }
  pairedSeen.clear();
  return Response.json({ role: record.role, fingerprint, label: record.label });
}

async function configRoute(env: Env): Promise<Response> {
  const login = await githubLogin(env).catch(() => null);
  return Response.json(deviceConfig(env, login), { headers: { "Cache-Control": "no-store" } });
}

function notConfigured(what: string): Response {
  return Response.json({ error: `${what} is not set up on this Worker.` }, { status: 404 });
}

/** Off without `WEBHOOK_SECRET`: the one-minute poll then does it all. */
async function receiveWebhook(request: Request, env: Env): Promise<Response> {
  if (!isSet(env.WEBHOOK_SECRET)) {
    return new Response("not found\n", { status: 404 });
  }
  const body = await request.arrayBuffer();
  if (!(await verifySignature(body, request.headers.get("X-Hub-Signature-256"), env.WEBHOOK_SECRET))) {
    return new Response("unauthenticated\n", { status: 401 });
  }
  const text = new TextDecoder().decode(body);
  const mark = parseDelivery(request.headers.get("X-GitHub-Event"), text, await githubLogin(env));
  if (mark) {
    await prIndex(env).mark(mark.repo, mark.number, mark.involved);
  }
  return new Response(null, { status: 202 });
}

/**
 * R2, then GitHub. No edge cache: it needs a custom domain, and the phone reads each version once and keeps it.
 */
async function serveVersioned(key: string, contentType: string, load: () => Promise<Response>, env: Env,
  context: ExecutionContext): Promise<Response> {
  const stored = await env.DIFFS.get(key);
  if (stored) {
    return new Response(stored.body, { headers: { "Content-Type": contentType } });
  }
  const live = await load();
  if (!live.ok) {
    return live;
  }
  const bytes = await live.arrayBuffer();
  context.waitUntil(env.DIFFS.put(key, bytes.slice(0)));
  return new Response(bytes, { headers: { "Content-Type": contentType } });
}

async function liveDetail(repo: string, number: number, env: Env): Promise<Response> {
  const id = `${repo}#${number}`;
  const pr = (await readPullRequests([{ id, repo, number }], env)).get(id);
  return pr
    ? Response.json({ ...pr.detail, title: pr.title, revision: pr.revision, version: pr.version })
    : new Response("not found\n", { status: 404 });
}

/** With a version, the stored copy. Without one, GitHub now: a PR on an agent's list need not be on Jai's. */
async function write(repo: string, number: number, request: Request, env: Env): Promise<Response> {
  const input = await request.json();
  const ref = clientRefOf(input);
  const receipt = ref && `write:${repo}#${number}:${ref}`;
  if (receipt) {
    const claim = await prIndex(env).claimWrite(receipt, Date.now());
    if (claim === "busy") {
      return busyAnswer();
    }
    if (claim === "done") {
      return liveDetail(repo, number, env);
    }
  }
  const failure = await writeToGitHub(repo, number, input, env);
  if (receipt) {
    await prIndex(env).finishWrite(receipt, failure === null, Date.now());
  }
  if (failure) {
    return failure;
  }
  await prIndex(env).mark(repo, number, true);
  return liveDetail(repo, number, env);
}

/** The answer if it is there, and 202 while the job runs. A model call outlasts any one request. */
async function aiAnswer(job: AiJob, isRetry: boolean, env: Env): Promise<Response> {
  const key = aiKey(job);
  if (isRetry) {
    await env.DIFFS.delete(key);
  }
  const stored = await env.DIFFS.get(key);
  if (stored) {
    return new Response(stored.body, { headers: { "Content-Type": "application/json" } });
  }
  await aiJobs(env).enqueue(job);
  return Response.json({ status: "working" }, { status: 202 });
}

function aiRoute(
  kind: "key_lines" | "rewrite", repo: string, number: number, params: URLSearchParams, env: Env,
): Promise<Response> {
  const head = params.get("head") ?? "";
  const context = Number(params.get("context") ?? DEFAULT_CONTEXT);
  if (!COMMIT.test(head) || !Number.isInteger(context) || context < -1 || context > MAX_CONTEXT) {
    return Promise.resolve(new Response("bad request\n", { status: 400 }));
  }
  return aiAnswer({ kind, repo, number, head, context }, params.get("retry") === "1", env);
}

/** The conversation on a GET, a question on a POST, and the reason in its own words when one can't go. */
async function askRoute(repo: string, number: number, request: Request, env: Env): Promise<Response> {
  let receipt: string | null = null;
  try {
    if (request.method !== "POST") {
      return Response.json(await askChat(repo, number, env));
    }
    const body = await request.json();
    const input = parseAskInput(body);
    if (!input) {
      return Response.json({ error: "That question can't be sent." }, { status: 400 });
    }
    const ref = clientRefOf(body);
    receipt = ref && `ask:${repo}#${number}:${ref}`;
    const claim = receipt ? await prIndex(env).claimWrite(receipt, Date.now()) : "go";
    if (claim === "busy") {
      return busyAnswer();
    }
    if (claim === "go") {
      await ask(repo, number, input, env);
      if (receipt) {
        await prIndex(env).finishWrite(receipt, true, Date.now());
      }
    }
    return Response.json(await askChat(repo, number, env));
  } catch (error) {
    if (error instanceof AskRefused && receipt) {
      await prIndex(env).finishWrite(receipt, false, Date.now());
    }
    if (error instanceof AskRefused) {
      return Response.json({ error: error.message }, { status: 422 });
    }
    console.error("ask failed", error);
    return Response.json({ error: "The AI couldn't be reached. Try again." }, { status: 502 });
  }
}

const FEEDBACK_PATH = /^\/feedback(?:\/([^/]+))?$/;

/** The list on a GET of /feedback and new feedback on a POST; one piece's chat, and a reply to it, on /feedback/{id}. */
async function feedbackRoute(id: string | undefined, request: Request, env: Env): Promise<Response> {
  if (id !== undefined && !isFeedbackId(id)) {
    return new Response("not found\n", { status: 404 });
  }
  let receipt: string | null = null;
  try {
    if (request.method !== "POST") {
      return Response.json(id ? await feedbackChat(id, env) : await feedbackList(env));
    }
    const body = await request.json();
    const input = parseFeedbackInput(body);
    if (!input) {
      return Response.json({ error: "That feedback can't be sent." }, { status: 400 });
    }
    const ref = clientRefOf(body);
    receipt = ref && `feedback:${id ?? "new"}:${ref}`;
    const claim = receipt ? await prIndex(env).claimWrite(receipt, Date.now()) : "go";
    if (claim === "busy") {
      return busyAnswer();
    }
    let target = id;
    if (claim === "go") {
      if (target) {
        await sendFeedback(target, input, env);
      } else {
        target = await startFeedback(input, env);
      }
      if (receipt) {
        await prIndex(env).finishWrite(receipt, true, Date.now());
      }
    }
    if (!target) {
      // A repeat of new feedback already sent: the newest thread is it.
      target = (await feedbackList(env)).threads[0]?.id;
    }
    return target ? Response.json(await feedbackChat(target, env)) : Response.json({ error: "Not found." }, { status: 404 });
  } catch (error) {
    console.error("feedback failed", error);
    return Response.json({ error: "The builder agent couldn't be reached. Try again." }, { status: 502 });
  }
}

function pullRequestRoute(
  match: RegExpExecArray, params: URLSearchParams, request: Request, env: Env, context: ExecutionContext,
): Promise<Response> {
  const [, owner, name, number, kind] = match;
  const repo = `${owner}/${name}`;
  const pr = Number(number);
  if (kind === "write") {
    return request.method === "POST" ? write(repo, pr, request, env)
      : Promise.resolve(new Response("not found\n", { status: 404 }));
  }
  if (kind === "ask") {
    return askConfigured(env) ? askRoute(repo, pr, request, env) : Promise.resolve(notConfigured("Ask AI"));
  }
  if (kind === "key-lines" || kind === "rewrite") {
    if (!isSet(env.ANTHROPIC_API_KEY)) {
      return Promise.resolve(notConfigured(kind === "rewrite" ? "Rewrite" : "Key lines"));
    }
    return aiRoute(kind === "rewrite" ? "rewrite" : "key_lines", repo, pr, params, env);
  }
  if (kind === "diff") {
    const revision = params.get("revision");
    const load = () => fetchDiff(repo, pr, env);
    return revision && VERSION.test(revision)
      ? serveVersioned(diffKey(repo, pr, revision), "text/plain", load, env, context)
      : load();
  }
  const version = params.get("version");
  const load = () => liveDetail(repo, pr, env);
  return version && VERSION.test(version)
    ? serveVersioned(detailKey(repo, pr, version), "application/json", load, env, context)
    : load();
}

async function deviceRoute(pathname: string, request: Request, env: Env): Promise<Response | null> {
  if (pathname === "/device/config" && request.method === "GET") {
    return configRoute(env);
  }
  if (request.method === "DELETE" && pathname === "/device/pair") {
    const secret = deviceSecretOf(request.headers.get("Authorization"));
    if (secret) {
      await prIndex(env).unpair(await sha256Hex(secret));
      pairedSeen.clear();
    }
    return new Response(null, { status: 204 });
  }
  if (request.method !== "POST") {
    return null;
  }
  if (pathname === "/device/register") {
    const { token, host } = (await request.json()) as { token: string; host: ApnsHost };
    await prIndex(env).registerDevice(token, host);
    return new Response(null, { status: 204 });
  }
  if (pathname === "/device/event") {
    const { kind, ...detail } = (await request.json()) as { kind: string } & Record<string, unknown>;
    await prIndex(env).record(kind, detail);
    return new Response(null, { status: 204 });
  }
  return null;
}

export default {
  async fetch(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
    const { pathname, searchParams } = new URL(request.url);
    if (pathname === "/") {
      return new Response("hello world\n");
    }
    if (pathname === "/github/webhook" && request.method === "POST") {
      return receiveWebhook(request, env);
    }
    if (pathname === "/github/setup") {
      return createAppPage(request, searchParams, env);
    }
    if (pathname === "/device/pair" && request.method === "POST") {
      return pairRoute(request, env);
    }
    if (pathname === "/github/callback") {
      return finishAppCreation(searchParams, env);
    }
    if (pathname === "/prs/states" && request.method === "POST") {
      return hasToken(request, env.HUB_TOKEN) ? statesRoute(request, env)
        : new Response("unauthorized\n", { status: 401 });
    }
    if (!(await isAuthorized(request, env))) {
      return new Response("unauthorized\n", { status: 401 });
    }
    if (pathname === "/prs/merged") {
      const kind = searchParams.get("of") === "reviewed" ? "reviewed" : "mine";
      return Response.json({ prs: await mergedPullRequests(env, kind) });
    }
    if (pathname === "/prs") {
      return Response.json(await prIndex(env).rows());
    }
    if (pathname === "/tick" && request.method === "POST") {
      await prIndex(env).tick(Date.now());
      return new Response(null, { status: 204 });
    }
    if (pathname === "/push-state") {
      return Response.json(await prIndex(env).pushState());
    }
    if (pathname === "/events") {
      return Response.json(await prIndex(env).events(Number(searchParams.get("limit")) || 200));
    }
    if (pathname === "/github/app-credentials" && request.method === "POST") {
      const stored = await env.DIFFS.get("setup/github-app.json");
      await env.DIFFS.delete("setup/github-app.json");
      return stored ? new Response(stored.body) : new Response("none\n", { status: 404 });
    }
    const device = await deviceRoute(pathname, request, env);
    if (device) {
      return device;
    }
    const feedback = FEEDBACK_PATH.exec(pathname);
    if (feedback) {
      return feedbackConfigured(env) ? feedbackRoute(feedback[1], request, env) : notConfigured("Feedback");
    }
    const pullRequest = PULL_REQUEST_PATH.exec(pathname);
    if (pullRequest) {
      return pullRequestRoute(pullRequest, searchParams, request, env, context);
    }
    return new Response("not found\n", { status: 404 });
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    await prIndex(env).tick(controller.scheduledTime);
  },
};
