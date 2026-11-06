import Anthropic from "@anthropic-ai/sdk";
import { chatOf } from "./ask-chat.ts";
import type { AskChat } from "./ask-chat.ts";
import type { Env } from "./env.ts";

/**
 * Feedback on the app itself, from the app: each piece starts a Managed Agents session on the builder agent, whose tools
 * run on Borg Cube 04 (a self-hosted environment; `builder/` holds the worker). There it changes `jai/agent-pager`,
 * tests, pushes to main and ships a build. A session's events are the conversation; this keeps only the list.
 */

/** Hard stop on one piece of feedback's spend, at list price, in cents. */
const SESSION_BUDGET_CENTS = "1000";
const MAX_TEXT = 8_000;
const THREADS_KEY = "feedback/threads.json";
const SESSION_ID = /^sesn_[A-Za-z0-9]{1,64}$/;

export interface FeedbackThread {
  id: string;
  title: string;
  createdAt: string;
}

export interface FeedbackInput {
  text: string;
  /** The app's build, so the agent knows what Jai was looking at. */
  build: string | null;
}

export interface FeedbackChat extends AskChat {
  id: string;
  /** Whether the builder Mac is taking work. Without it a message waits in the queue. */
  builderOnline: boolean;
}

function client(env: Env): Anthropic {
  return new Anthropic({ apiKey: env.ASK_ANTHROPIC_API_KEY });
}

export function isFeedbackId(id: string): boolean {
  return SESSION_ID.test(id);
}

export function parseFeedbackInput(body: unknown): FeedbackInput | null {
  const { text, build } = (body ?? {}) as { text?: unknown; build?: unknown };
  if (typeof text !== "string" || !text.trim() || text.length > MAX_TEXT) {
    return null;
  }
  return { text: text.trim(), build: typeof build === "string" && /^[\w.-]{1,20}$/.test(build) ? build : null };
}

/** What the agent reads: the words, and the build they are about. The chat shows the words alone. */
export function feedbackPrompt({ text, build }: FeedbackInput): string {
  return build ? `Jai is on build ${build}.\n\nFeedback: ${text}` : `Feedback: ${text}`;
}

export function titleOf(text: string): string {
  const line = text.split("\n")[0].trim();
  return line.length > 60 ? `${line.slice(0, 59)}…` : line;
}

async function threads(env: Env): Promise<FeedbackThread[]> {
  const stored = await env.DIFFS.get(THREADS_KEY);
  return stored ? await stored.json<FeedbackThread[]>() : [];
}

async function builderOnline(env: Env): Promise<boolean> {
  try {
    const stats = await client(env).beta.environments.work.stats(env.FEEDBACK_ENVIRONMENT_ID!);
    return (stats.workers_polling ?? 0) > 0;
  } catch {
    return false;
  }
}

export async function feedbackList(env: Env): Promise<{ threads: FeedbackThread[]; builderOnline: boolean }> {
  const [list, online] = await Promise.all([threads(env), builderOnline(env)]);
  return { threads: list, builderOnline: online };
}

export async function feedbackChat(id: string, env: Env): Promise<FeedbackChat> {
  const events = [];
  for await (const event of client(env).beta.sessions.events.list(id)) {
    events.push(event);
  }
  const [session, online] = await Promise.all([client(env).beta.sessions.retrieve(id), builderOnline(env)]);
  const cost = session.usage?.list_cost?.amount;
  const chat = chatOf(events as Parameters<typeof chatOf>[0], cost === undefined ? null : Number(cost), "Feedback: ");
  return { ...chat, id, builderOnline: online, activity: chat.activity === "Reading the repo" ? "Working" : chat.activity };
}

/** A new piece of feedback: its own session, first in the list. */
export async function startFeedback(input: FeedbackInput, env: Env): Promise<string> {
  const session = await client(env).beta.sessions.create({
    agent: env.FEEDBACK_AGENT_ID!,
    environment_id: env.FEEDBACK_ENVIRONMENT_ID!,
    title: titleOf(input.text),
    budget: { type: "limit", max_list_cost: { amount: SESSION_BUDGET_CENTS, currency: "USD" } },
  });
  await sendFeedback(session.id, input, env);
  const list = await threads(env);
  await env.DIFFS.put(THREADS_KEY, JSON.stringify(
    [{ id: session.id, title: titleOf(input.text), createdAt: new Date().toISOString() }, ...list],
  ));
  return session.id;
}

export async function sendFeedback(id: string, input: FeedbackInput, env: Env): Promise<void> {
  await client(env).beta.sessions.events.send(id, {
    events: [{ type: "user.message", content: [{ type: "text", text: feedbackPrompt(input) }] }],
  });
}
