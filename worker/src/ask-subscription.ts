// Ask on a subscription (docs/api.md, "AI on a subscription"): each question is one Agent SDK turn in the container, on a
// checkout of the PR at its head. The chat the phone reads and the session's transcript live in R2, so any container can
// take the next question.
import { AskFailure, askEvent, errorWords, failedLine, scrubbed, sideOf } from "./ask-trace.ts";
import { type AgentAnswer, askContainer } from "./agent-container.ts";
import { type AskChat, type AskInput, type AskMessage, askPrompt, askRecordKey } from "./ask-chat.ts";
import type { AskGrant } from "./app-token.ts";
import type { PrFacts } from "./ask-setup.ts";
import { type Env, scopedKey } from "./env.ts";
import { getFromGitHub, liveDiff } from "./github.ts";
import { isRevisionOf, type RepoFullName, type Sha } from "./ids.ts";
import { BUILT_IN_DEFAULTS, type ModelChoice, sameChoice } from "./models.ts";

/** Said with every question: a session begun before the diff file existed reads only its first system prompt. */
const DIFF_NOTE = "The PR's diff at this head is in .prhub-pr.diff at the repository's root. Read it first.";

/**
 * The container a person's questions run in: their own, so one person's checkouts and clones are never on the disk
 * another person's agent reads. Key lines and rewrites, which read no files, share `ai`.
 */
export function askInstance(env: Pick<Env, "SIGNED_IN_USER_ID">): string {
  return `ask:${env.SIGNED_IN_USER_ID ?? "self"}`;
}

/** A turn that has run this long is taken as lost: the job that ran it ended without saying so. */
export const TURN_LOST_MS = 20 * 60_000;

export interface SubscriptionRecord {
  kind: "subscription";
  /** The Agent SDK session, once the first turn made one. */
  session: string | null;
  head: string;
  choice: ModelChoice;
  messages: AskMessage[];
  /** When the turn now running began; null when none runs. */
  workingSince: number | null;
  problem: string | null;
  costCents: number | null;
  model: string | null;
}

interface AskAnswer extends Partial<Omit<AgentAnswer, "output" | "tokens">> {
  error?: string;
  subtype?: string;
  text?: string | null;
  session?: string;
  entries?: unknown[];
  /** The tools the turn began with. */
  tools?: string[];
}

export function isSubscriptionRecord(record: unknown): record is SubscriptionRecord {
  return typeof record === "object" && record !== null && (record as { kind?: unknown }).kind === "subscription";
}

/**
 * The phone's chat from the record. No cost: the subscription is billed by plan, not by question. The record keeps what
 * the turns would have cost on the API, and each `ai_run` line logs it.
 */
export function subscriptionChat(record: SubscriptionRecord, now: number): AskChat {
  const lost = record.workingSince !== null && now - record.workingSince >= TURN_LOST_MS;
  const isWorking = record.workingSince !== null && !lost;
  return {
    messages: record.messages,
    isWorking,
    activity: isWorking ? "Reading the repo" : null,
    problem: lost ? "The agent stopped before it answered. Ask again." : record.problem,
    costCents: null,
    model: record.model,
    effort: record.choice.effort,
  };
}

function transcriptKey(repo: RepoFullName, number: number, env: Pick<Env, "SIGNED_IN_USER_ID">): string {
  return scopedKey(env, `ask-sessions/${repo}/${number}.json`);
}

const STOPS: Record<string, string> = {
  error_max_budget_usd: "This chat reached its spending limit.",
  error_max_turns: "The agent stopped after too many steps. Ask a narrower question.",
};

/**
 * One question: the record says working while the turn runs, then holds the answer or why there is none. A question at
 * another model or effort than the chat's starts a new chat, as on Managed Agents.
 */
export async function askOnSubscription(
  repo: RepoFullName, number: number, input: AskInput, choice: ModelChoice, env: Env,
  services: {
    system: () => Promise<string>; grant: () => Promise<AskGrant>; diff: () => Promise<string>; budgetUsd: number;
    /** Whether the token is read only by how it was made: only then may the agent's tools reach GitHub with it. */
    readOnly: boolean; now?: () => number;
    /** The turn's id, the question's own: its `ask_event` lines and its failure line carry it. */
    turn?: string;
  },
): Promise<void> {
  const now = services.now ?? Date.now;
  const turn = services.turn ?? crypto.randomUUID();
  const started = now();
  const trace = { pr: `${repo}#${number}`, user_id: env.SIGNED_IN_USER_ID ?? null };
  const key = askRecordKey(repo, number, env);
  const stored = await (await env.DIFFS.get(key))?.json<unknown>();
  const known = isSubscriptionRecord(stored) && sameChoice(stored.choice ?? BUILT_IN_DEFAULTS.ask, choice) ? stored : null;
  // A turn a deploy cut short runs again from the queue: its question is already in the chat, so it is not added twice,
  // and a turn whose answer is already there is done: the model is not asked again.
  const at = known?.messages.findIndex((message) => message.id === turn) ?? -1;
  const resumed = at >= 0;
  if (resumed && known!.messages.slice(at + 1).some((message) => message.role === "agent")) {
    askEvent("resumed", turn, { pr: `${repo}#${number}`, user_id: env.SIGNED_IN_USER_ID ?? null, already_answered: true });
    return;
  }
  const asked: AskMessage = {
    id: turn, role: "you", text: input.question,
    anchor: input.anchor ? `${input.anchor.path}:${input.anchor.line}` : null,
    ...(input.anchor ? { side: input.anchor.side } : {}),
  };
  askEvent(resumed ? "resumed" : "handed_over", turn, { ...trace, model: choice.model, effort: choice.effort });
  // A question after one that failed is its Retry, or its words edited: it takes the failed one's place.
  const before = known?.messages ?? [];
  const ended = known != null && (known.workingSince === null ? known.problem != null : now() - known.workingSince >= TURN_LOST_MS);
  const failedLast = !resumed && ended && before.at(-1)?.role === "you";
  let record: SubscriptionRecord = {
    kind: "subscription", session: known?.session ?? null, head: input.head, choice,
    messages: resumed ? before : [...(failedLast ? before.slice(0, -1) : before), asked], workingSince: now(), problem: null,
    costCents: known?.costCents ?? null, model: known?.model ?? null,
  };
  await env.DIFFS.put(key, JSON.stringify(record));
  let token: string | null = null;
  try {
    const entries = record.session ? await (await env.DIFFS.get(transcriptKey(repo, number, env)))?.json<unknown[]>() : [];
    const grant = await grantWithRetry(services.grant);
    token = grant.token;
    askEvent("grant", turn, { ...trace, ms: now() - started, read_only: services.readOnly, repos: grant.repos?.length ?? null,
      checked_by: grant.checkedBy ?? null });
    const answer = await askContainer<AskAnswer>("/ask", JSON.stringify({
      system: await services.system(), prompt: `${DIFF_NOTE}\n${askPrompt(input, null)}`, model: choice.model, effort: choice.effort,
      scope: env.SIGNED_IN_USER_ID ?? "self", repo, number,
      head: input.head, token: grant.token, readOnly: services.readOnly,
      reachable: grant.repos, diff: await services.diff(), session: record.session, entries: entries ?? [],
      budgetUsd: services.budgetUsd,
    }), env.AGENT!, undefined, askInstance(env));
    if (answer.error) {
      throw new AskFailure(MODEL_TROUBLE.test(answer.error) ? "model" : "container", answer.error);
    }
    askEvent("container", turn, { ...trace, ms: now() - started, subtype: answer.subtype ?? null, tools: answer.tools ?? null });
    if (answer.session && answer.entries) {
      await env.DIFFS.put(transcriptKey(repo, number, env), JSON.stringify(answer.entries));
    }
    const spent = answer.costUsd === null || answer.costUsd === undefined ? null : Math.round(answer.costUsd * 10_000) / 100;
    record = {
      ...record, session: answer.session ?? record.session, workingSince: null,
      messages: answer.text ? [...record.messages, { id: crypto.randomUUID(), role: "agent", text: answer.text, anchor: null }]
        : record.messages,
      problem: answer.subtype === "success" ? null : STOPS[answer.subtype ?? ""] ?? "The agent stopped before it answered.",
      costCents: spent === null ? record.costCents : (record.costCents ?? 0) + spent, model: answer.model ?? record.model,
    };
    console.log("ai_run", {
      feature: "ask", repo, number, auth: "subscription", user_id: env.SIGNED_IN_USER_ID ?? null, model: record.model,
      effort: choice.effort, session: record.session, cost_cents: spent, read_only: services.readOnly,
      reachable: grant.repos?.length ?? null, tools: answer.tools ?? null,
    });
    askEvent("answered", turn, { ...trace, ms: now() - started, model: record.model, cost_cents: spent });
  } catch (error) {
    const known = [token];
    record = { ...record, workingSince: null, problem: failedLine(error, turn, known) };
    askEvent("failed", turn, { ...trace, ms: now() - started, side: sideOf(error), reason: errorWords(error, known),
      status: error instanceof AskFailure ? error.status : null });
    console.error("ask on subscription failed", errorWords(error, known),
      scrubbed(error instanceof Error ? error.stack ?? "" : "", known));
  }
  await env.DIFFS.put(key, JSON.stringify(record));
}

/** What the model's side says when it, not the container, stopped the turn. */
const MODEL_TROUBLE = /usage limit|rate.?limit|overloaded|\b(429|529)\b|credit|invalid.*(token|api key)|authentication/i;

/** GitHub's token for the turn: a refusal says why at once; anything else, a blip, gets one more try. */
async function grantWithRetry(grant: () => Promise<AskGrant>): Promise<AskGrant> {
  try {
    return await grant();
  } catch (error) {
    if (error instanceof AskFailure) {
      throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
    return grant();
  }
}

/** The PR's title, author, branches, link, state and description, as the token reads them; null when GitHub won't say. */
export async function prFacts(repo: RepoFullName, number: number, env: Env): Promise<PrFacts | null> {
  try {
    const response = await getFromGitHub(`/repos/${repo}/pulls/${number}`, env);
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const pull = await response.json() as {
      title?: string; user?: { login?: string } | null; base?: { ref?: string }; head?: { ref?: string; label?: string };
      html_url?: string; state?: string; merged?: boolean; draft?: boolean; body?: string | null;
    };
    const state = pull.merged ? "merged" : pull.draft && pull.state === "open" ? "draft" : pull.state ?? null;
    return {
      title: pull.title ?? "", author: pull.user?.login ?? null, base: pull.base?.ref ?? null,
      head: pull.head?.label ?? pull.head?.ref ?? null, url: pull.html_url ?? `https://github.com/${repo}/pull/${number}`,
      state, body: pull.body ?? "",
    };
  } catch {
    return null;
  }
}

/** The diff the agent reads first, cut at `DIFF_KEPT` bytes. */
const DIFF_KEPT = 400_000;

/**
 * The PR's diff at `head`, read no further than `DIFF_KEPT` bytes. Empty when GitHub won't give one, or when the PR has
 * moved past `head`: a newer commit's diff beside an older checkout would mislead.
 */
export async function prDiff(repo: RepoFullName, number: number, head: Sha, env: Env): Promise<string> {
  const { response, version } = await liveDiff(repo, number, env);
  if (!response.ok || !response.body || !version || !isRevisionOf(version, head)) {
    await response.body?.cancel();
    return "";
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (size < DIFF_KEPT) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    const kept = value.slice(0, DIFF_KEPT - size);
    chunks.push(kept);
    size += kept.byteLength;
  }
  await reader.cancel();
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, at);
    at += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}
