// Ask on a subscription (docs/api.md, "AI on a subscription"): each question is one Agent SDK turn in the container, on a
// checkout of the PR at its head. The chat the phone reads and the session's transcript live in R2, so any container can
// take the next question.
import { type AgentAnswer, askContainer } from "./agent-container.ts";
import { type AskChat, type AskInput, type AskMessage, askPrompt, askRecordKey } from "./ask-chat.ts";
import { type Env, scopedKey } from "./env.ts";
import { liveDiff } from "./github.ts";
import { isRevisionOf, type RepoFullName, type Sha } from "./ids.ts";
import { BUILT_IN_DEFAULTS, type ModelChoice, sameChoice } from "./models.ts";

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
}

export function isSubscriptionRecord(record: unknown): record is SubscriptionRecord {
  return typeof record === "object" && record !== null && (record as { kind?: unknown }).kind === "subscription";
}

/** The phone's chat from the record. */
export function subscriptionChat(record: SubscriptionRecord, now: number): AskChat {
  const lost = record.workingSince !== null && now - record.workingSince >= TURN_LOST_MS;
  const isWorking = record.workingSince !== null && !lost;
  return {
    messages: record.messages,
    isWorking,
    activity: isWorking ? "Reading the repo" : null,
    problem: lost ? "The agent stopped before it answered. Ask again." : record.problem,
    costCents: record.costCents,
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
    system: string; token: () => Promise<string>; diff: () => Promise<string>; budgetUsd: number; now?: () => number;
  },
): Promise<void> {
  const now = services.now ?? Date.now;
  const key = askRecordKey(repo, number, env);
  const stored = await (await env.DIFFS.get(key))?.json<unknown>();
  const known = isSubscriptionRecord(stored) && sameChoice(stored.choice ?? BUILT_IN_DEFAULTS.ask, choice) ? stored : null;
  const asked: AskMessage = {
    id: crypto.randomUUID(), role: "you", text: input.question,
    anchor: input.anchor ? `${input.anchor.path}:${input.anchor.line}` : null,
  };
  let record: SubscriptionRecord = {
    kind: "subscription", session: known?.session ?? null, head: input.head, choice,
    messages: [...(known?.messages ?? []), asked], workingSince: now(), problem: null,
    costCents: known?.costCents ?? null, model: known?.model ?? null,
  };
  await env.DIFFS.put(key, JSON.stringify(record));
  try {
    const entries = record.session ? await (await env.DIFFS.get(transcriptKey(repo, number, env)))?.json<unknown[]>() : [];
    const answer = await askContainer<AskAnswer>("/ask", JSON.stringify({
      system: services.system, prompt: askPrompt(input, null), model: choice.model, effort: choice.effort,
      scope: env.SIGNED_IN_USER_ID ?? "self", repo, number,
      head: input.head, token: await services.token(), diff: await services.diff(), session: record.session, entries: entries ?? [],
      budgetUsd: services.budgetUsd,
    }), env.AGENT!);
    if (answer.error) {
      throw new Error(answer.error);
    }
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
      effort: choice.effort, session: record.session, cost_cents: spent,
    });
  } catch (error) {
    record = { ...record, workingSince: null, problem: "The AI couldn't be reached. Ask again." };
    console.error("ask on subscription failed", error);
  }
  await env.DIFFS.put(key, JSON.stringify(record));
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
    const kept = value.subarray(0, DIFF_KEPT - size);
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
