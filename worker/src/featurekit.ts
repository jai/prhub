/**
 * The FeedbackKit Worker (docs/featurekit.md): one Worker that keeps every app's feedback. An app's own Worker checks
 * who is asking, as it does for every route, and forwards `/feedback` here with the app and the sender's GitHub login.
 * Per app, the config names who builds: an owner's feedback goes to a coding agent that ships, a builder's to one that
 * opens a pull request, and anyone else's opens a public issue. The runner on Jai's Mac takes the agents' work.
 */
import {
  addFeedback, feedbackChat, feedbackList, type FeedbackStore, isFeedbackId, parseAgentSide, parseFeedbackInput,
  r2Store, runnerAgent, runnerClaim, runnerPoll, runnerResult,
} from "./feedback.ts";
import {
  addIssueFeedback, gitHubIssues, type IssueFeedback, issueChat, issuesNotice, issueThreads, isImageName,
} from "./feedback-issues.ts";
import { sha256Hex } from "./pairing.ts";
import { clientRefOf } from "./write-receipts.ts";

export interface FeatureKitEnv {
  FEEDBACK: R2Bucket;
  /** `{"<app>": {"repo": "owner/name", "owners": [logins], "builders": [logins], "issues": true}}`. */
  APPS: string;
  /** The app Workers' bearer: they have checked the sender, and say who it is. */
  CALLER_TOKEN: string;
  /** The runner's bearer. */
  RUNNER_TOKEN: string;
  /** Opens the public issues: a token that can open issues on each app's repo. */
  ISSUES_TOKEN?: string;
}

export type Role = "owner" | "builder" | "issue";

export interface AppConfig {
  repo: string;
  owners: string[];
  builders: string[];
  issues: boolean;
}

const APP_NAME = /^[a-z][a-z0-9-]{0,39}$/;
const LOGIN = /^[A-Za-z0-9-]{1,39}$/;

export function parseApps(raw: string): Record<string, AppConfig> {
  const parsed = JSON.parse(raw) as Record<string, Partial<AppConfig>>;
  const lower = (logins: unknown) => Array.isArray(logins)
    ? logins.filter((login): login is string => typeof login === "string").map((login) => login.toLowerCase()) : [];
  return Object.fromEntries(Object.entries(parsed).filter(([name, app]) => APP_NAME.test(name)
    && typeof app?.repo === "string" && /^[\w.-]+\/[\w.-]+$/.test(app.repo)).map(([name, app]) => [name, {
    repo: app.repo!, owners: lower(app.owners), builders: lower(app.builders), issues: app.issues === true,
  }]));
}

export function roleOf(app: AppConfig, login: string): Role | null {
  const name = login.toLowerCase();
  return app.owners.includes(name) ? "owner" : app.builders.includes(name) ? "builder" : app.issues ? "issue" : null;
}

/** One sender's own corner of the bucket: their chats, whichever kind. */
export function senderPrefix(app: string, login: string): string {
  return `apps/${app}/users/${login.toLowerCase()}/`;
}

export function prefixed(store: FeedbackStore, prefix: string): FeedbackStore {
  return {
    get: (key) => store.get(`${prefix}${key}`),
    put: (key, value, ifEtag) => store.put(`${prefix}${key}`, value, ifEtag),
    list: async (key) => (await store.list(`${prefix}${key}`)).map((one) => one.slice(prefix.length)),
    delete: (key) => store.delete(`${prefix}${key}`),
  };
}

const IMAGES = "images/";
const IMAGE_PATH = /^\/images\/([^/]+)$/;
const FEEDBACK_PATH = /^\/feedback(?:\/([^/]+))?$/;
const RUNNER_PATH = /^\/runner\/(poll|claim|result|agent)$/;

function hasBearer(request: Request, token: string | undefined): boolean {
  return !!token && request.headers.get("Authorization") === `Bearer ${token}`;
}

async function bodyOf(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

const notFound = () => Response.json({ error: "Not found." }, { status: 404 });

/** The sender's chats: an agent's (owner, builder) or issues, by their role in the app. */
async function feedbackRoute(
  id: string | undefined, request: Request, env: FeatureKitEnv, app: string, config: AppConfig, login: string,
): Promise<Response> {
  if (id !== undefined && !isFeedbackId(id)) {
    return notFound();
  }
  const role = roleOf(config, login);
  if (!role) {
    return Response.json({ error: "Feedback is not open to you in this app." }, { status: 403 });
  }
  const bucket = r2Store(env.FEEDBACK);
  const store = prefixed(bucket, senderPrefix(app, login));
  const now = Date.now();
  if (role !== "issue") {
    if (request.method !== "POST") {
      if (!id) {
        const { threads, builderOnline } = await feedbackList(store, now);
        return Response.json({ threads, builderOnline });
      }
      const chat = await feedbackChat(store, id, now);
      return chat ? Response.json(chat) : notFound();
    }
    const body = await bodyOf(request);
    const input = parseFeedbackInput(body);
    if (!input) {
      return Response.json({ error: "That feedback can't be sent." }, { status: 400 });
    }
    const target = await once(store, id, body, () => addFeedback(store, id ?? null, input, now));
    const chat = target ? await feedbackChat(store, target, now) : null;
    return chat ? Response.json(chat) : notFound();
  }
  if (!env.ISSUES_TOKEN) {
    return Response.json({ error: "Feedback issues are not set up." }, { status: 503 });
  }
  const context: IssueFeedback = {
    store,
    images: {
      async put(name, image) {
        const bytes = Uint8Array.from(atob(image.data), (char) => char.charCodeAt(0));
        await env.FEEDBACK.put(`${IMAGES}${name}`, bytes, { httpMetadata: { contentType: image.media_type } });
      },
    },
    issues: gitHubIssues(config.repo, env.ISSUES_TOKEN),
    login,
    origin: new URL(request.url).origin,
    imagePath: "/images/",
    repo: config.repo,
    now: Date.now,
  };
  if (request.method !== "POST") {
    if (!id) {
      return Response.json({ threads: await issueThreads(store), builderOnline: true, notice: issuesNotice(config.repo) });
    }
    const chat = await issueChat(context, id);
    return chat ? Response.json(chat) : notFound();
  }
  const body = await bodyOf(request);
  const input = parseFeedbackInput(body);
  if (!input) {
    return Response.json({ error: "That feedback can't be sent." }, { status: 400 });
  }
  const target = await once(store, id, body, () => addIssueFeedback(context, id ?? null, input));
  const chat = target ? await issueChat(context, target) : null;
  return chat ? Response.json(chat) : notFound();
}

/**
 * A send with a `client_ref` is kept once: a retry answers the chat its first try made, and sends nothing again.
 * Two tries at the same moment can both go; the app's outbox sends one at a time.
 */
async function once(
  store: FeedbackStore, id: string | undefined, body: unknown, send: () => Promise<string | null>,
): Promise<string | null> {
  const ref = clientRefOf(body);
  const key = ref ? `refs/${await sha256Hex(`${id ?? "new"}:${ref}`)}.json` : null;
  const seen = key ? (await store.get<{ chat: string }>(key))?.value.chat : undefined;
  if (seen) {
    return seen;
  }
  const chat = await send();
  if (key && chat) {
    // Sent already: a receipt that can't be kept must not answer an error, or the app sends it again.
    await store.put(key, { chat }).catch((error) => console.error("feedback receipt not kept", error));
  }
  return chat;
}

/** Which chats a runner message is about: the app, the sender and their store, from the body. */
function senderOf(body: Record<string, unknown> | null, apps: Record<string, AppConfig>, bucket: FeedbackStore) {
  const app = typeof body?.app === "string" ? body.app : "";
  const login = typeof body?.login === "string" ? body.login : "";
  const config = apps[app];
  const role = config && LOGIN.test(login) ? roleOf(config, login) : null;
  return config && role && role !== "issue"
    ? { app, login: login.toLowerCase(), config, role, store: prefixed(bucket, senderPrefix(app, login)) } : null;
}

async function runnerRoute(kind: string, request: Request, env: FeatureKitEnv, apps: Record<string, AppConfig>) {
  const bucket = r2Store(env.FEEDBACK);
  const body = (await bodyOf(request)) as Record<string, unknown> | null;
  const now = Date.now();
  if (kind === "poll") {
    const detail = typeof body?.detail === "string" ? body.detail : null;
    const senders = Object.entries(apps).flatMap(([app, config]) => [...config.owners, ...config.builders]
      .map((login) => ({ app, login, config, role: roleOf(config, login)! })));
    const work = await Promise.all(senders.map(async ({ app, login, config, role }) =>
      (await runnerPoll(prefixed(bucket, senderPrefix(app, login)), body?.orca === true, now, detail))
        .map((item) => ({ ...item, app, login, repo: config.repo, role }))));
    return Response.json({ work: work.flat().sort((a, b) => a.at - b.at) });
  }
  const sender = senderOf(body, apps, bucket);
  if (!sender) {
    return Response.json({ error: "no such app or sender" }, { status: 404 });
  }
  const chat = typeof body?.chat === "string" ? body.chat : "";
  const message = typeof body?.message === "string" ? body.message : "";
  if (kind === "claim") {
    const claimed = await runnerClaim(sender.store, chat, message, now);
    return claimed.ok ? Response.json({ ...claimed, app: sender.app, login: sender.login, repo: sender.config.repo, role: sender.role })
      : Response.json({ error: claimed.status === 404 ? "no such message" : "not pending" }, { status: claimed.status });
  }
  if (kind === "result") {
    const delivered = body?.status === "delivered";
    if (!delivered && body?.status !== "failed") {
      return Response.json({ error: "status is delivered or failed" }, { status: 400 });
    }
    const detail = typeof body?.detail === "string" ? body.detail.slice(0, 300) : null;
    const status = await runnerResult(sender.store, chat, message, delivered, detail);
    return Response.json(status === 200 ? { ok: true } : { error: status === 404 ? "no such message" : "not delivering" },
      { status });
  }
  const agent = parseAgentSide(body, now);
  if (!agent) {
    return Response.json({ error: "not an agent side" }, { status: 400 });
  }
  const status = await runnerAgent(sender.store, chat, agent);
  return Response.json(status === 200 ? { ok: true } : { error: "no such chat" }, { status });
}

async function imageRoute(name: string, env: FeatureKitEnv): Promise<Response> {
  const object = isImageName(name) ? await env.FEEDBACK.get(`${IMAGES}${name}`) : null;
  return object
    ? new Response(object.body, {
      headers: {
        "Content-Type": object.httpMetadata?.contentType ?? "image/jpeg",
        "Cache-Control": "public, max-age=31536000, immutable",
      },
    })
    : new Response("not found\n", { status: 404 });
}

export async function serveFeatureKit(request: Request, env: FeatureKitEnv): Promise<Response> {
  const { pathname } = new URL(request.url);
  const image = IMAGE_PATH.exec(pathname);
  if (image && request.method === "GET") {
    return imageRoute(image[1], env);
  }
  const apps = parseApps(env.APPS);
  const runner = RUNNER_PATH.exec(pathname);
  if (runner && request.method === "POST") {
    return hasBearer(request, env.RUNNER_TOKEN) ? runnerRoute(runner[1], request, env, apps)
      : new Response("unauthorized\n", { status: 401 });
  }
  const feedback = FEEDBACK_PATH.exec(pathname);
  if (feedback) {
    if (!hasBearer(request, env.CALLER_TOKEN)) {
      return new Response("unauthorized\n", { status: 401 });
    }
    const app = request.headers.get("X-FeedbackKit-App") ?? "";
    const login = request.headers.get("X-FeedbackKit-Login") ?? "";
    const config = apps[app];
    if (!config || !LOGIN.test(login)) {
      return Response.json({ error: "Unknown app or sender." }, { status: 400 });
    }
    try {
      return await feedbackRoute(feedback[1], request, env, app, config, login);
    } catch (error) {
      console.error("feedback failed", error);
      return Response.json({ error: "Your feedback couldn't be kept. Try again." }, { status: 502 });
    }
  }
  return new Response("not found\n", { status: 404 });
}

export default { fetch: serveFeatureKit };
