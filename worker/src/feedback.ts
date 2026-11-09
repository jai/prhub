import Anthropic from "@anthropic-ai/sdk";
import { chatOf } from "./ask-chat.ts";
import type { AskChat, AskMessage } from "./ask-chat.ts";
import type { Env } from "./env.ts";

/**
 * Feedback on the app itself, from the app: each piece starts a Managed Agents session on the builder agent, whose tools
 * run in a self-hosted environment. There it changes `jai/agent-pager`,
 * tests, pushes to main and ships a build. A session's events are the conversation; this keeps only the list.
 */

/** Hard stop on one piece of feedback's spend, at list price, in cents. */
const SESSION_BUDGET_CENTS = "1000";
const MAX_TEXT = 8_000;
/** Screenshots on one message: how many, and each one's size decoded. The app sends JPEGs of at most 1568 px. */
const MAX_IMAGES = 4;
const MAX_IMAGE_BYTES = 1_500_000;
/** What an image may be, and the base64 its bytes start with, so a mislabelled file is refused. */
const IMAGE_STARTS = { "image/jpeg": "/9j/", "image/png": "iVBORw0KGgo" } as const;
type ImageType = keyof typeof IMAGE_STARTS;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const THREADS_KEY = "feedback/threads.json";
const SESSION_ID = /^sesn_[A-Za-z0-9]{1,64}$/;

export interface FeedbackThread {
  id: string;
  title: string;
  createdAt: string;
}

export interface FeedbackImage {
  media_type: ImageType;
  /** The bytes in base64, as the API takes them. */
  data: string;
}

export interface FeedbackInput {
  text: string;
  /** The app's build, so the agent knows what Jai was looking at. */
  build: string | null;
  /** Screenshots, which the agent sees as images beside the words. */
  images: FeedbackImage[];
}

/** A message of the chat, with how many screenshots Jai sent on it. */
export interface FeedbackMessage extends AskMessage {
  images: number;
}

export interface FeedbackChat extends AskChat {
  messages: FeedbackMessage[];
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

/** Words, screenshots or both; `null` for anything the builder should not get. */
export function parseFeedbackInput(body: unknown): FeedbackInput | null {
  const { text, build, images } = (body ?? {}) as { text?: unknown; build?: unknown; images?: unknown };
  const pictures = parseImages(images);
  if (typeof text !== "string" || text.length > MAX_TEXT || pictures === null || (!text.trim() && !pictures.length)) {
    return null;
  }
  return {
    text: text.trim(),
    build: typeof build === "string" && /^[\w.-]{1,20}$/.test(build) ? build : null,
    images: pictures,
  };
}

function parseImages(value: unknown): FeedbackImage[] | null {
  if (value === undefined || value === null) {
    return [];
  }
  if (!Array.isArray(value) || value.length > MAX_IMAGES) {
    return null;
  }
  const images: FeedbackImage[] = [];
  for (const item of value) {
    const { media_type: type, data } = (item ?? {}) as { media_type?: unknown; data?: unknown };
    if (typeof type !== "string" || !(type in IMAGE_STARTS) || typeof data !== "string" || data.length % 4 !== 0
      || data.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4 || !BASE64.test(data)
      || !data.startsWith(IMAGE_STARTS[type as ImageType])) {
      return null;
    }
    images.push({ media_type: type as ImageType, data });
  }
  return images;
}

/** What the agent reads: the words, and the build they are about. The chat shows the words alone. */
export function feedbackPrompt({ text, build, images }: FeedbackInput): string {
  const words = text || "(no words: see the screenshot)";
  const shots = images.length === 0 ? "" : images.length === 1
    ? "He attached a screenshot of the app; it is the image with this message.\n\n"
    : `He attached ${images.length} screenshots of the app; they are the images with this message.\n\n`;
  return `${build ? `Jai is on build ${build}.\n\n` : ""}${shots}Feedback: ${words}`;
}

/** The user message the builder gets: the prompt, then each screenshot as an image block. */
export function feedbackContent(input: FeedbackInput) {
  return [
    { type: "text" as const, text: feedbackPrompt(input) },
    ...input.images.map((image) => ({
      type: "image" as const,
      source: { type: "base64" as const, media_type: image.media_type, data: image.data },
    })),
  ];
}

export function titleOf(text: string): string {
  if (!text.trim()) {
    return "Screenshot";
  }
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
  return {
    ...chat, messages: withImageCounts(chat.messages, events), id, builderOnline: online,
    activity: chat.activity === "Reading the repo" ? "Working" : chat.activity,
  };
}

/** Each message with the screenshots its event carried; the chat shows the count, not the pictures. */
export function withImageCounts(
  messages: AskMessage[], events: Array<{ id: string; type: string; content?: Array<{ type: string }> }>,
): FeedbackMessage[] {
  const counts = new Map(events.map((event) => [
    event.id, event.type === "user.message" ? (event.content ?? []).filter((block) => block.type === "image").length : 0,
  ]));
  return messages.map((message) => {
    const images = counts.get(message.id) ?? 0;
    // A screenshot alone was sent with a placeholder for words; the chat shows none.
    return { ...message, images, text: images && message.text === "(no words: see the screenshot)" ? "" : message.text };
  });
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
    events: [{ type: "user.message", content: feedbackContent(input) }],
  });
}
