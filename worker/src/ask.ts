import Anthropic from "@anthropic-ai/sdk";
import { askPrompt, chatOf } from "./ask-chat";
import type { AskChat, AskInput } from "./ask-chat";
import { type Env, isSet } from "./env";

/**
 * Asking about a PR: one Managed Agents session per PR, on the agent and environment `scripts/ask-agent.mts` made once.
 * The session holds the conversation and a checkout, and sessions last until deleted, so this keeps only which one is
 * this PR's. A repo is fixed for a session's life; its GitHub token isn't, and each question brings a fresh one. On Jai's
 * Worker that is minted by the Ask GitHub App, read only across every repo it is installed on. A self-hosted Worker
 * has no App: its own PAT goes instead, `ASK_GITHUB_TOKEN` (read only) or else `GITHUB_TOKEN`. The same token is
 * `GH_TOKEN` in the vault, for GitHub's API.
 */

/** Hard stop on one PR's spend, at list price, in cents. */
const SESSION_BUDGET_CENTS = "200";

/** A session from before the vault can't reach GitHub's API, and a vault can't be added to one: it starts again. */
const RECORD_VERSION = 2;

interface AskRecord {
  session: string;
  resource: string;
  head: string;
  version?: number;
}

export class AskRefused extends Error {}

function client(env: Env): Anthropic {
  return new Anthropic({ apiKey: isSet(env.ASK_ANTHROPIC_API_KEY) ? env.ASK_ANTHROPIC_API_KEY : env.ANTHROPIC_API_KEY });
}

function recordKey(repo: string, number: number): string {
  return `ask/${repo}/${number}.json`;
}

async function readRecord(repo: string, number: number, env: Env): Promise<AskRecord | null> {
  const stored = await env.DIFFS.get(recordKey(repo, number));
  return stored ? await stored.json<AskRecord>() : null;
}

function base64url(data: ArrayBuffer | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function appJwt(env: Env): Promise<string> {
  const der = Uint8Array.from(atob((env.ASK_GITHUB_APP_KEY ?? "").replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const now = Math.floor(Date.now() / 1000);
  const body = `${base64url('{"alg":"RS256","typ":"JWT"}')}.${
    base64url(JSON.stringify({ iat: now - 30, exp: now + 500, iss: env.ASK_GITHUB_APP_ID }))}`;
  return `${body}.${base64url(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(body)))}`;
}

/** The App path when its id and key are set; a PAT otherwise. */
function repoToken(repo: string, env: Env): Promise<string> {
  if (isSet(env.ASK_GITHUB_APP_ID) && isSet(env.ASK_GITHUB_APP_KEY)) {
    return appRepoToken(repo, env);
  }
  return Promise.resolve(isSet(env.ASK_GITHUB_TOKEN) ? env.ASK_GITHUB_TOKEN : env.GITHUB_TOKEN);
}

/** Read access for an hour to the repos the Ask GitHub App is on: all the agent can do on GitHub, whatever it is told to try. */
async function appRepoToken(repo: string, env: Env): Promise<string> {
  const headers = {
    Accept: "application/vnd.github+json", Authorization: `Bearer ${await appJwt(env)}`, "User-Agent": "pr-viewer",
  };
  const installation = await fetch(`https://api.github.com/repos/${repo}/installation`, { headers });
  if (!installation.ok) {
    throw new AskRefused(`The AI can't read ${repo}: the Ask GitHub App isn't installed there.`);
  }
  const { id } = await installation.json<{ id: number }>();
  const minted = await fetch(`https://api.github.com/app/installations/${id}/access_tokens`, {
    method: "POST", headers,
    body: JSON.stringify({
      permissions: {
        contents: "read", pull_requests: "read", issues: "read", checks: "read", actions: "read", statuses: "read",
        metadata: "read",
      },
    }),
  });
  if (!minted.ok) {
    throw new AskRefused(`GitHub wouldn't give the AI read access to ${repo} (${minted.status}).`);
  }
  return (await minted.json<{ token: string }>()).token;
}

async function startSession(repo: string, number: number, head: string, token: string, env: Env): Promise<AskRecord> {
  const session = await client(env).beta.sessions.create({
    agent: env.ASK_AGENT_ID!,
    environment_id: env.ASK_ENVIRONMENT_ID!,
    vault_ids: [env.ASK_VAULT_ID!],
    title: `${repo}#${number}`,
    budget: { type: "limit", max_list_cost: { amount: SESSION_BUDGET_CENTS, currency: "USD" } },
    resources: [{
      type: "github_repository", url: `https://github.com/${repo}`, authorization_token: token,
      checkout: { type: "commit", sha: head },
    }],
  });
  const resource = session.resources.find((one) => one.type === "github_repository");
  if (!resource) {
    throw new AskRefused("The session started without its repo.");
  }
  return { session: session.id, resource: resource.id, head, version: RECORD_VERSION };
}

/** This PR's session with a fresh token, or a new one when it has ended: a repo's token lasts an hour. */
async function liveRecord(repo: string, number: number, head: string, env: Env): Promise<AskRecord> {
  const token = await repoToken(repo, env);
  await client(env).beta.vaults.credentials.update(env.ASK_CREDENTIAL_ID!, {
    vault_id: env.ASK_VAULT_ID!, auth: { type: "environment_variable", secret_value: token },
  });
  const known = await readRecord(repo, number, env);
  if (known?.version === RECORD_VERSION) {
    const { status } = await client(env).beta.sessions.retrieve(known.session);
    if (status !== "terminated") {
      await client(env).beta.sessions.resources.update(known.resource, {
        session_id: known.session, authorization_token: token,
      });
      return known;
    }
  }
  return startSession(repo, number, head, token, env);
}

export async function askChat(repo: string, number: number, env: Env): Promise<AskChat> {
  const record = await readRecord(repo, number, env);
  if (!record) {
    return chatOf([], null);
  }
  const events = [];
  for await (const event of client(env).beta.sessions.events.list(record.session)) {
    events.push(event);
  }
  const session = await client(env).beta.sessions.retrieve(record.session);
  const cost = session.usage?.list_cost?.amount;
  return chatOf(events as Parameters<typeof chatOf>[0], cost === undefined ? null : Number(cost));
}

/** Sends the question. The route reads the conversation after, so a repeat that finds this sent reads it too. */
export async function ask(repo: string, number: number, input: AskInput, env: Env): Promise<void> {
  const record = await liveRecord(repo, number, input.head, env);
  await client(env).beta.sessions.events.send(record.session, {
    events: [{ type: "user.message", content: [{ type: "text", text: askPrompt(input, record.head) }] }],
  });
  await env.DIFFS.put(recordKey(repo, number), JSON.stringify({ ...record, head: input.head }));
}
