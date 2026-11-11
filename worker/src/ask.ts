import Anthropic from "@anthropic-ai/sdk";
import { askPrompt, askRecordKey, chatOf, QUESTION } from "./ask-chat";
import type { AskChat, AskInput } from "./ask-chat";
import { type Env, isSet } from "./env";
import { prId, type RepoFullName } from "./ids";
import { askRepoToken, InstallationTokenRefused } from "./app-token";
import { askBudgetOf, limitsOf } from "./limits";
import { BUILT_IN_DEFAULTS, type ModelChoice, sameChoice } from "./models";

/**
 * Asking about a PR: one Managed Agents session per PR, on the agent and environment `scripts/ask-agent.mts` made once.
 * The session holds the conversation and a checkout, and sessions last until deleted, so this keeps only which one is
 * this PR's. A repo is fixed for a session's life; its GitHub token isn't, and each question brings a fresh one. On Jai's
 * Worker that is minted by the Ask GitHub App, read only across every repo it is installed on. A self-hosted Worker
 * has no App: its own PAT goes instead, `ASK_GITHUB_TOKEN` (read only) or else `GITHUB_TOKEN`. On the hosted Worker
 * the PRHub App mints it, read only and for this one repo, after the person's own token has read the PR: an
 * installation token reaches repos the person may not, so it is never minted for one they can't see. The same token is
 * `GH_TOKEN` in the vault, for GitHub's API. A hosted person's sessions run in their own Anthropic org, on their key, and
 * which session is a PR's is kept under their R2 prefix.
 *
 * A session's model and effort are fixed when it starts (an `agent_with_overrides`); Managed Agents can't change them
 * per message. So a question asked at another model or effort than the session's starts a new session, and the chat
 * the phone sees is that new one.
 */

/** A session from before the vault can't reach GitHub's API, and a vault can't be added to one: it starts again. */
const RECORD_VERSION = 2;

interface AskRecord {
  session: string;
  resource: string;
  head: string;
  version?: number;
  /** Absent on a session from before the choice existed: it ran on the agent's own model, Opus 5.5 at medium. */
  choice?: ModelChoice;
}

export class AskRefused extends Error {}

function client(env: Env): Anthropic {
  return new Anthropic({ apiKey: isSet(env.ASK_ANTHROPIC_API_KEY) ? env.ASK_ANTHROPIC_API_KEY : env.ANTHROPIC_API_KEY });
}


async function readRecord(repo: RepoFullName, number: number, env: Env): Promise<AskRecord | null> {
  const stored = await env.DIFFS.get(askRecordKey(repo, number, env));
  return stored ? await stored.json<AskRecord>() : null;
}

async function startSession(
  repo: RepoFullName, number: number, head: string, token: string, choice: ModelChoice, env: Env,
): Promise<AskRecord> {
  const session = await client(env).beta.sessions.create({
    agent: {
      type: "agent_with_overrides", id: env.ASK_AGENT_ID!, model: { id: choice.model, effort: choice.effort },
    },
    environment_id: env.ASK_ENVIRONMENT_ID!,
    vault_ids: [env.ASK_VAULT_ID!],
    title: prId(repo, number),
    budget: { type: "limit", max_list_cost: { amount: String(askBudgetOf(limitsOf(env))), currency: "USD" } },
    resources: [{
      type: "github_repository", url: `https://github.com/${repo}`, authorization_token: token,
      checkout: { type: "commit", sha: head },
    }],
  });
  const resource = session.resources.find((one) => one.type === "github_repository");
  if (!resource) {
    throw new AskRefused("The session started without its repo.");
  }
  return { session: session.id, resource: resource.id, head, version: RECORD_VERSION, choice };
}

/**
 * This PR's session with a fresh token, or a new one when it has ended or runs at another model or effort: a repo's token
 * lasts an hour.
 */
async function liveRecord(repo: RepoFullName, number: number, head: string, choice: ModelChoice, env: Env): Promise<AskRecord> {
  const token = await askRepoToken(repo, number, env).catch((error: unknown) => {
    throw error instanceof InstallationTokenRefused ? new AskRefused(error.message) : error;
  });
  await client(env).beta.vaults.credentials.update(env.ASK_CREDENTIAL_ID!, {
    vault_id: env.ASK_VAULT_ID!, auth: { type: "environment_variable", secret_value: token },
  });
  const known = await readRecord(repo, number, env);
  if (known?.version === RECORD_VERSION && sameChoice(known.choice ?? BUILT_IN_DEFAULTS.ask, choice)) {
    const { status } = await client(env).beta.sessions.retrieve(known.session);
    if (status !== "terminated") {
      await client(env).beta.sessions.resources.update(known.resource, {
        session_id: known.session, authorization_token: token,
      });
      return known;
    }
  }
  return startSession(repo, number, head, token, choice, env);
}

export async function askChat(repo: RepoFullName, number: number, env: Env): Promise<AskChat> {
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
  const { id: model, effort } = session.agent.model;
  const level = typeof effort === "string" ? effort : effort?.type;
  return chatOf(
    events as Parameters<typeof chatOf>[0], cost === undefined ? null : Number(cost), QUESTION,
    { model, effort: level ?? null },
  );
}

/**
 * Sends the question. The route reads the conversation after, so a repeat that finds this sent reads it too. Each
 * question is one `ai_run` log line; its cost is the session's, read from Anthropic, as the turn has not run yet.
 */
export async function ask(repo: RepoFullName, number: number, input: AskInput, choice: ModelChoice, env: Env): Promise<void> {
  const record = await liveRecord(repo, number, input.head, choice, env);
  await client(env).beta.sessions.events.send(record.session, {
    events: [{ type: "user.message", content: [{ type: "text", text: askPrompt(input, record.head) }] }],
  });
  console.log("ai_run", {
    feature: "ask", repo, number, user_id: env.SIGNED_IN_USER_ID ?? null, model: choice.model, effort: choice.effort,
    session: record.session,
  });
  await env.DIFFS.put(askRecordKey(repo, number, env), JSON.stringify({ ...record, head: input.head }));
}
