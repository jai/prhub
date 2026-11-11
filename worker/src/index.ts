// PRHub's Worker: the PRs its owner should look at, each one's diff, and word to the phone when they change.
// Contract: docs/api.md.
import { statesRoute } from "./pr-states";
import { AiJobs, type AiJob } from "./ai-jobs";
import { askChat } from "./ask";
import { acceptAsk, askPr, withQueued } from "./ask-queue";
import { bodyOf, parseAskInput, parseKeyLineMark } from "./boundary";
import { eventRoute, registerRoute, unpairRoute } from "./devices";
import { aiConfigOf, askConfigured, deviceConfig, feedbackConfigured } from "./config";
import { aiJobs, askQueue, type Env, githubLogin, isSet, prIndex, scopedKey } from "./env";
import { aiStoreKey } from "./ai-run";
import {
  detailVersionOf, fetchDiff, liveDiff, mergedPullRequests, pullRequestSummary, readPullRequests, reviewWeek,
} from "./github";
import { parseRepoFullName, parseSha, prId, type RepoFullName } from "./ids";
import {
  addFeedback, feedbackChat, feedbackList, isFeedbackId, listServedLog, parseAgentSide, parseFeedbackInput, r2Store, runnerAgent,
  runnerClaim, runnerPoll, runnerResult,
} from "./feedback";
import { DEFAULT_CONTEXT } from "./key-lines";
import { type AiConfig, type AiFeature, resolveChoice } from "./models";
import { detailKey, diffKey, PrIndex } from "./pr-index";
import { codeHashOf, deviceSecretOf, fingerprintOf, isPairedSecret, normalizePairingCode } from "./pairing";
import {
  fetchRepoIndex, isRepoIndex, rankRepos, type RepoIndex, REPOS_FORCED_GAP_MS, REPOS_KEY, REPOS_RETRY_GAP_MS,
  REPOS_STALE_MS,
} from "./repos";
import { createAppPage, finishAppCreation } from "./setup";
import { type LiveRead, serveVersioned } from "./versioned";
import { parseDelivery, verifySignature } from "./webhook";
import { writeToGitHub } from "./write";
import { carryRoute } from "./carry";
import { busyAnswer, clientRefOf } from "./write-receipts";

import { Installation, IpLimit, SignIn, UserAccount } from "./account";
import {
  authenticate, configInstallations, hostedAccountConfig, hostedMode, publicHostedRoute, servicesOf, userEnv,
} from "./hosted";
import { pairingLimitAnswer, personLimitAnswer, reportedLimitsOf } from "./limit-enforcement";
import { LimitName } from "./limits";

export { AiJobs, Installation, IpLimit, PrIndex, SignIn, UserAccount };

const PULL_REQUEST_PATH =
  /^\/prs\/([\w.-]+)\/([\w.-]+)\/(\d+)\/(diff|detail|summary|write|key-lines-reviewed|key-lines|rewrite|ask)$/;
/** GraphQL's `Int`: a bigger number is no PR, and GitHub would refuse the query for it. */
const MAX_PR_NUMBER = 2_147_483_647;
const VERSION = /^[\w.:-]{1,200}$/;
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

/** Jai's app's `APP_TOKEN`, as ever, or the device secret of an app paired with this Worker, asked of the index. */
async function isAuthorized(request: Request, env: Env): Promise<boolean> {
  return hasToken(request, env.APP_TOKEN) || isPairedSecret(request.headers.get("Authorization"), prIndex(env));
}

function errorAnswer(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}

/** `POST /device/pair` (docs/api.md): a one-time code admits the device secret sent as the bearer. */
async function pairRoute(request: Request, env: Env): Promise<Response> {
  const secret = deviceSecretOf(request.headers.get("Authorization"));
  if (!secret) {
    return errorAnswer(401, "unauthorized", "send the app's device secret as the bearer");
  }
  const limited = await pairingLimitAnswer(request, env);
  if (limited) {
    return limited;
  }
  const body = await request.json().catch(() => null) as { code?: unknown } | null;
  const code = normalizePairingCode(body?.code);
  if (!code) {
    return errorAnswer(400, "validation_error", "code must be the 8-character pairing code");
  }
  const fingerprint = await fingerprintOf(secret);
  const record = await prIndex(env).pair(await codeHashOf(code), fingerprint, Date.now());
  if (!record) {
    return errorAnswer(401, "pairing_code_invalid", "unknown, used or expired pairing code");
  }
  return Response.json({ role: record.role, fingerprint, label: record.label });
}

/** Config problems already in `/events` from this isolate, by the vars that caused them. */
let reportedAiConfig: string | null = null;

/** The AI model config. Its problems go to `/events` once per isolate and per value; the parsed fallbacks serve on. */
function aiConfig(env: Env, context: ExecutionContext): AiConfig {
  const config = aiConfigOf(env);
  const key = JSON.stringify([env.AI_MODELS_ALLOWED, env.AI_EFFORT_MAX, env.AI_DEFAULTS]);
  if (config.problems.length > 0 && reportedAiConfig !== key) {
    reportedAiConfig = key;
    console.error("AI model config problems", config.problems);
    context.waitUntil(prIndex(env).record("ai_config_error", { problems: config.problems }));
  }
  return config;
}

/** The request's `model` and `effort` within what this Worker allows, or a 400 saying what is. */
function choiceOf(
  feature: AiFeature, requested: { model?: unknown; effort?: unknown }, env: Env, context: ExecutionContext,
) {
  const result = resolveChoice(aiConfig(env, context), feature, requested);
  return result.ok ? result : { ok: false as const, answer: errorAnswer(400, "invalid_model_choice", result.error) };
}

async function configRoute(env: Env, context: ExecutionContext, extra: object = {}): Promise<Response> {
  aiConfig(env, context);
  reportedLimitsOf(env, (promise) => context.waitUntil(promise));
  const login = await githubLogin(env).catch(() => null);
  return Response.json({ ...deviceConfig(env, login), ...extra }, { headers: { "Cache-Control": "no-store" } });
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

/** A PR's detail now, under the version the index would keep it as (`detailVersionOf`). */
async function liveDetail(repo: RepoFullName, number: number, env: Env): Promise<LiveRead> {
  const id = prId(repo, number);
  const pr = (await readPullRequests([{ id, repo, number }], env)).get(id);
  return pr
    ? {
      response: Response.json({ ...pr.detail, title: pr.title, revision: pr.revision, version: pr.version }),
      version: await detailVersionOf(pr),
    }
    : { response: new Response("not found\n", { status: 404 }), version: null };
}

/** With a version, the stored copy. Without one, GitHub now: a PR on an agent's list need not be on Jai's. */
async function write(repo: RepoFullName, number: number, request: Request, env: Env): Promise<Response> {
  const body = await bodyOf(request);
  if (!body) {
    return Response.json({ error: "That is not something the viewer can post." }, { status: 400 });
  }
  const input = body.value;
  const ref = clientRefOf(input);
  const receipt = ref && `write:${prId(repo, number)}:${ref}`;
  if (receipt) {
    const claim = await prIndex(env).claimWrite(receipt, Date.now());
    if (claim === "busy") {
      return busyAnswer();
    }
    if (claim === "done") {
      return (await liveDetail(repo, number, env)).response;
    }
  }
  const limited = await personLimitAnswer(env, [LimitName.WritesPerMinute, LimitName.WritesPerHour], receipt);
  if (limited) {
    if (receipt) {
      await prIndex(env).finishWrite(receipt, false, Date.now());
    }
    return limited;
  }
  const failure = await writeToGitHub(repo, number, input, env);
  if (receipt) {
    await prIndex(env).finishWrite(receipt, failure === null, Date.now());
  }
  if (failure) {
    return failure;
  }
  await prIndex(env).mark(repo, number, true);
  return (await liveDetail(repo, number, env)).response;
}

/** The answer if it is there, and 202 while the job runs. A model call outlasts any one request. */
async function aiAnswer(job: AiJob, isRetry: boolean, env: Env): Promise<Response> {
  const key = aiStoreKey(job, env);
  if (isRetry) {
    await env.DIFFS.delete(key);
  }
  const stored = await env.DIFFS.get(key);
  if (stored) {
    return new Response(stored.body, { headers: { "Content-Type": "application/json" } });
  }
  const limited = await personLimitAnswer(env, [LimitName.AiJobsPerHour], key);
  if (limited) {
    return limited;
  }
  await aiJobs(env).enqueue(job, isSet(env.SIGNED_IN_USER_ID) ? env.SIGNED_IN_USER_ID : null);
  return Response.json({ status: "working" }, { status: 202 });
}

function aiRoute(
  kind: "key_lines" | "rewrite", repo: RepoFullName, number: number, params: URLSearchParams, env: Env,
  executionContext: ExecutionContext,
): Promise<Response> {
  const head = parseSha(params.get("head"));
  const context = Number(params.get("context") ?? DEFAULT_CONTEXT);
  if (!head || !Number.isInteger(context) || context < -1 || context > MAX_CONTEXT) {
    return Promise.resolve(new Response("bad request\n", { status: 400 }));
  }
  const requested = { model: params.get("model") || null, effort: params.get("effort") || null };
  const chosen = choiceOf(kind, requested, env, executionContext);
  if (!chosen.ok) {
    return Promise.resolve(chosen.answer);
  }
  return aiAnswer({ kind, repo, number, head, context, choice: chosen.choice }, params.get("retry") === "1", env);
}

/**
 * `GET` and `POST /prs/{owner}/{repo}/{n}/key-lines-reviewed` (docs/api.md, "Reviewed key lines"): the key lines checked
 * off at a head, kept in the index so each of the person's devices shows the same ticks.
 */
async function reviewedRoute(
  repo: RepoFullName, number: number, params: URLSearchParams, request: Request, env: Env,
): Promise<Response> {
  const pr = prId(repo, number);
  if (request.method !== "POST") {
    const head = parseSha(params.get("head"));
    return head
      ? Response.json(await prIndex(env).reviewedKeyLines(pr, head), { headers: { "Cache-Control": "no-store" } })
      : errorAnswer(400, "validation_error", "head must be the PR's head commit");
  }
  const mark = parseKeyLineMark((await bodyOf(request))?.value);
  if (!mark) {
    return errorAnswer(400, "validation_error", "send {head, line, reviewed}");
  }
  const marked = await prIndex(env).markKeyLine(pr, mark.head, mark.line, mark.reviewed, Date.now());
  return marked ? Response.json(marked) : errorAnswer(400, "too_many", "this PR has as many reviewed lines as it keeps");
}

/**
 * The conversation on a GET, with the questions the agent doesn't have yet. A question on a POST is stored and answered
 * `202` at once; the agent gets it from the ask queue's alarm (`ask-queue.ts`), so the phone never waits on GitHub or
 * the agent.
 */
async function askRoute(
  repo: RepoFullName, number: number, request: Request, env: Env, context: ExecutionContext,
): Promise<Response> {
  const pr = askPr(repo, number);
  if (request.method !== "POST") {
    try {
      const chat = await askChat(repo, number, env);
      return Response.json(withQueued(chat, await askQueue(env).readAsks(pr, chat), Date.now()));
    } catch (error) {
      console.error("ask chat failed", error);
      return Response.json({ error: "The AI couldn't be reached. Try again." }, { status: 502 });
    }
  }
  const body = (await bodyOf(request))?.value;
  const input = parseAskInput(body);
  if (!input) {
    return Response.json({ error: "That question can't be sent." }, { status: 400 });
  }
  const { model, effort } = (body ?? {}) as { model?: unknown; effort?: unknown };
  const chosen = choiceOf("ask", { model, effort }, env, context);
  if (!chosen.ok) {
    return chosen.answer;
  }
  const ref = clientRefOf(body);
  const receipt = ref && `ask:${prId(repo, number)}:${ref}`;
  const question = {
    id: ref ?? crypto.randomUUID(), repo, number, input, choice: chosen.choice, at: Date.now(), error: null,
  };
  const userId = isSet(env.SIGNED_IN_USER_ID) ? env.SIGNED_IN_USER_ID : null;
  return acceptAsk({
    claim: (key) => prIndex(env).claimWrite(key, Date.now()),
    finish: (key, sent) => prIndex(env).finishWrite(key, sent, Date.now()),
    limited: (key) => personLimitAnswer(env, [LimitName.AskQuestionsPerHour, LimitName.AskQuestionsPerDay], key),
    queue: (stored) => askQueue(env).queueAsk(stored, pr, userId),
    busy: busyAnswer,
  }, question, receipt);
}

const FEEDBACK_PATH = /^\/feedback(?:\/([^/]+))?$/;
const RUNNER_PATH = /^\/feedback\/runner\/(poll|claim|result|agent)$/;

/**
 * The list on a GET of /feedback and new feedback on a POST; one chat, and a reply to it, on /feedback/{id}. Each POST
 * only keeps the message for the runner (docs/api.md, "Feedback").
 */
async function feedbackRoute(id: string | undefined, request: Request, env: Env): Promise<Response> {
  if (id !== undefined && !isFeedbackId(id)) {
    return new Response("not found\n", { status: 404 });
  }
  const store = r2Store(env.DIFFS);
  let receipt: string | null = null;
  try {
    if (request.method !== "POST") {
      if (!id) {
        const list = await feedbackList(store, Date.now());
        console.log(listServedLog(list.builderStatus, list.threads.length, Date.now()));
        return Response.json(list);
      }
      const answer = await feedbackChat(store, id, Date.now());
      return answer ? Response.json(answer) : Response.json({ error: "Not found." }, { status: 404 });
    }
    const body = (await bodyOf(request))?.value;
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
    let target: string | null | undefined = id;
    if (claim === "go") {
      target = await addFeedback(store, id ?? null, input, Date.now());
      if (receipt) {
        await prIndex(env).finishWrite(receipt, target !== null, Date.now());
      }
    } else if (!target) {
      // A repeat of new feedback already kept: the newest chat is it.
      target = (await feedbackList(store, Date.now())).threads[0]?.id;
    }
    const chat = target ? await feedbackChat(store, target, Date.now()) : null;
    return chat ? Response.json(chat) : Response.json({ error: "Not found." }, { status: 404 });
  } catch (error) {
    console.error("feedback failed", error);
    if (receipt) {
      await prIndex(env).finishWrite(receipt, false, Date.now());
    }
    return Response.json({ error: "Your feedback couldn't be kept. Try again." }, { status: 502 });
  }
}

/** The runner on Jai's Mac (`HUB_TOKEN`): it polls, claims a message, says how its delivery went, and sends the agent's side. */
async function runnerRoute(kind: string, request: Request, env: Env): Promise<Response> {
  const store = r2Store(env.DIFFS);
  const body = ((await bodyOf(request))?.value ?? null) as Record<string, unknown> | null;
  const chat = typeof body?.chat === "string" ? body.chat : "";
  const message = typeof body?.message === "string" ? body.message : "";
  const now = Date.now();
  if (kind === "poll") {
    const detail = typeof body?.detail === "string" ? body.detail : null;
    return Response.json({ work: await runnerPoll(store, body?.orca === true, now, detail) });
  }
  if (kind === "claim") {
    const claimed = await runnerClaim(store, chat, message, now);
    return claimed.ok ? Response.json(claimed)
      : Response.json({ error: claimed.status === 404 ? "no such message" : "not pending" }, { status: claimed.status });
  }
  if (kind === "result") {
    const delivered = body?.status === "delivered";
    const detail = typeof body?.detail === "string" ? body.detail.slice(0, 300) : null;
    if (!delivered && body?.status !== "failed") {
      return Response.json({ error: "status is delivered or failed" }, { status: 400 });
    }
    const status = await runnerResult(store, chat, message, delivered, detail);
    return Response.json(status === 200 ? { ok: true } : { error: status === 404 ? "no such message" : "not delivering" },
      { status });
  }
  const agent = parseAgentSide(body, now);
  if (!agent) {
    return Response.json({ error: "not an agent side" }, { status: 400 });
  }
  const status = await runnerAgent(store, chat, agent);
  return Response.json(status === 200 ? { ok: true } : { error: "no such chat" }, { status });
}

/** `GET /prs/{owner}/{repo}/{n}/summary`: a picker row for any PR, read live, so a typed number shows what it opens. */
async function summaryRoute(repo: RepoFullName, number: number, env: Env): Promise<Response> {
  if (number < 1 || number > MAX_PR_NUMBER) {
    return errorAnswer(404, "not_found", "no such pull request");
  }
  try {
    const summary = await pullRequestSummary(repo, number, env);
    return summary ? Response.json(summary) : errorAnswer(404, "not_found", "no such pull request");
  } catch (error) {
    console.error("summary failed", error);
    return errorAnswer(502, "github_unavailable", "GitHub could not be asked");
  }
}

async function storedRepoIndex(env: Env): Promise<RepoIndex | null> {
  const stored = await env.DIFFS.get(scopedKey(env, REPOS_KEY));
  const value: unknown = stored ? await stored.json().catch(() => null) : null;
  return isRepoIndex(value) ? value : null;
}

async function refreshRepoIndex(env: Env, now: number): Promise<RepoIndex> {
  const index = await fetchRepoIndex(env, now);
  await env.DIFFS.put(scopedKey(env, REPOS_KEY), JSON.stringify(index), { httpMetadata: { contentType: "application/json" } });
  return index;
}

/**
 * `GET /repos` (docs/api.md, "Quick jump"). The copy in R2 answers at once; one over six hours old is read
 * again behind the answer, and `?refresh=1` reads it again first, at most every five minutes.
 */
async function reposRoute(params: URLSearchParams, env: Env, context: ExecutionContext): Promise<Response> {
  const now = Date.now();
  const index = prIndex(env);
  let current = await storedRepoIndex(env);
  const isForced = params.get("refresh") === "1";
  if (!current || (isForced && await index.claimRepoRefresh(now, REPOS_FORCED_GAP_MS))) {
    if (!current) {
      await index.claimRepoRefresh(now, 0);
    }
    try {
      current = await refreshRepoIndex(env, now);
    } catch (error) {
      console.error("repo index failed", error);
      if (!current) {
        return errorAnswer(502, "github_unavailable", "GitHub could not be asked for the repos");
      }
    }
  } else if (now - Date.parse(current.updatedAt) >= REPOS_STALE_MS
    && await index.claimRepoRefresh(now, REPOS_RETRY_GAP_MS)) {
    context.waitUntil(refreshRepoIndex(env, now).catch((error) => console.error("repo index failed", error)));
  }
  const listed = new Map(Object.entries(await index.listedCounts()));
  return Response.json(rankRepos(current, listed), { headers: { "Cache-Control": "no-store" } });
}

function pullRequestRoute(
  match: RegExpExecArray, params: URLSearchParams, request: Request, env: Env, context: ExecutionContext,
): Promise<Response> {
  const [, owner, name, number, kind] = match;
  const repo = parseRepoFullName(`${owner}/${name}`);
  const pr = Number(number);
  if (!repo) {
    return Promise.resolve(new Response("not found\n", { status: 404 }));
  }
  if (kind === "summary") {
    return summaryRoute(repo, pr, env);
  }
  if (kind === "write") {
    return request.method === "POST" ? write(repo, pr, request, env)
      : Promise.resolve(new Response("not found\n", { status: 404 }));
  }
  if (kind === "ask") {
    return askConfigured(env) ? askRoute(repo, pr, request, env, context) : Promise.resolve(notConfigured("Ask AI"));
  }
  if (kind === "key-lines-reviewed") {
    return reviewedRoute(repo, pr, params, request, env);
  }
  if (kind === "key-lines" || kind === "rewrite") {
    if (!isSet(env.ANTHROPIC_API_KEY)) {
      return Promise.resolve(notConfigured(kind === "rewrite" ? "Rewrite" : "Key lines"));
    }
    return aiRoute(kind === "rewrite" ? "rewrite" : "key_lines", repo, pr, params, env, context);
  }
  // R2, then GitHub. No edge cache: it needs a custom domain, and the phone reads each version once and keeps it.
  const waitUntil = (promise: Promise<unknown>) => context.waitUntil(promise);
  if (kind === "diff") {
    const revision = params.get("revision");
    const load = () => liveDiff(repo, pr, env);
    return revision && VERSION.test(revision)
      ? serveVersioned(env.DIFFS, scopedKey(env, diffKey(repo, pr, revision)), revision, "text/plain", load, waitUntil)
      : fetchDiff(repo, pr, env);
  }
  const version = params.get("version");
  const load = () => liveDetail(repo, pr, env);
  return version && VERSION.test(version)
    ? serveVersioned(env.DIFFS, scopedKey(env, detailKey(repo, pr, version)), version, "application/json", load, waitUntil)
    : load().then((live) => live.response);
}

async function deviceRoute(
  pathname: string, request: Request, env: Env, context: ExecutionContext,
): Promise<Response | null> {
  if (pathname === "/device/config" && request.method === "GET") {
    return configRoute(env, context);
  }
  if (request.method === "DELETE" && pathname === "/device/pair") {
    return unpairRoute(request, prIndex(env));
  }
  if (request.method !== "POST") {
    return null;
  }
  if (pathname === "/device/register") {
    return registerRoute(request, prIndex(env));
  }
  if (pathname === "/device/event") {
    return eventRoute(request, prIndex(env));
  }
  return null;
}

/** Every route behind a bearer, for whoever `env` acts as: the operator, or one signed-in hosted person. */
async function serveAuthorized(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
  const { pathname, searchParams } = new URL(request.url);
  if (pathname === "/prs/merged") {
    const kind = searchParams.get("of") === "reviewed" ? "reviewed" : "mine";
    return Response.json({ prs: await mergedPullRequests(env, kind) });
  }
  if (pathname === "/prs") {
    return Response.json(await prIndex(env).rows());
  }
  if (pathname === "/repos" && request.method === "GET") {
    return reposRoute(searchParams, env, context);
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
  const device = await deviceRoute(pathname, request, env, context);
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
}

/**
 * The hosted Worker (`hosted.ts`): sign-in routes, then every other route with the signed-in person's session, acting
 * with their token. `GET /device/config` answers a signed-out session too, with `account.state`, so the app can say why.
 */
async function serveHosted(
  request: Request, env: Env, context: ExecutionContext, app: { clientId: string; clientSecret: string },
): Promise<Response> {
  const services = servicesOf(env);
  const open = publicHostedRoute(request, env, services, app, (promise) => context.waitUntil(promise));
  if (open) {
    return open;
  }
  const isConfig = new URL(request.url).pathname === "/device/config" && request.method === "GET";
  const auth = await authenticate(request, env, services);
  if ("answer" in auth) {
    const session = auth.session;
    return isConfig && session
      ? configRoute(userEnv(env, { ...session, token: "" }), context, hostedAccountConfig(session))
      : auth.answer;
  }
  if (isConfig) {
    const installations = await configInstallations(request, auth.session, services,
      (promise) => context.waitUntil(promise));
    return configRoute(auth.env, context, hostedAccountConfig(auth.session, installations));
  }
  return serveAuthorized(request, auth.env, context);
}

export default {
  async fetch(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/") {
      return new Response("hello world\n");
    }
    const hosted = hostedMode(env);
    if (hosted.kind === "misconfigured") {
      console.error("HOSTED=on without", hosted.missing);
      return Response.json({ error: { code: "not_configured", message: "This Worker's hosted mode is not set up." } },
        { status: 503 });
    }
    if (hosted.kind === "on") {
      return serveHosted(request, env, context, hosted.app);
    }
    return serveOwner(request, env, context, false);
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    // Hosted: each person's account ticks their own index (`UserAccount.alarm`); there is no one person to poll for.
    if (hostedMode(env).kind === "off") {
      await tickOwnerIndex(env, controller.scheduledTime);
    }
  },
};

/** One person's PRs on their own token: this Worker unhosted, or a host that imports the library (`lib.ts`). */
export function tickOwnerIndex(env: Env, time: number): Promise<void> {
  return prIndex(env).tick(time);
}

/**
 * Every route of a one-person Worker. `isHostAuthorized`: a host that imports the library (`lib.ts`) has checked the
 * caller with its own credentials; the routes that carry their own (webhook, hub, `APP_TOKEN`) still check them.
 */
export async function serveOwner(
  request: Request, env: Env, context: ExecutionContext, isHostAuthorized: boolean,
): Promise<Response> {
  const { pathname, searchParams } = new URL(request.url);
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
  const runner = RUNNER_PATH.exec(pathname);
  if (runner && request.method === "POST") {
    return hasToken(request, env.HUB_TOKEN) && feedbackConfigured(env) ? runnerRoute(runner[1], request, env)
      : new Response("unauthorized\n", { status: 401 });
  }
  if (pathname === "/prs/states" && request.method === "POST") {
    return hasToken(request, env.HUB_TOKEN) ? statesRoute(request, env, reviewWeek(env))
      : new Response("unauthorized\n", { status: 401 });
  }
  if (!isHostAuthorized && !(await isAuthorized(request, env))) {
    return new Response("unauthorized\n", { status: 401 });
  }
  const carried = await carryRoute(pathname, request, env);
  return carried ?? serveAuthorized(request, env, context);
}
