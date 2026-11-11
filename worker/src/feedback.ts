import type { AskChat, AskMessage } from "./ask-chat.ts";

/**
 * Feedback on the app, from the app (docs/api.md, "Feedback"). The Worker only keeps it: each message waits here until
 * the owner's runner takes it, starts or tells a coding agent on the owner's Mac, and brings the agent's words back.
 * Nothing here calls a model. The runner reaches out to the Worker; the Worker never reaches the runner.
 */

const MAX_TEXT = 8_000;
/** Screenshots on one message: how many, and each one's size decoded. The app sends JPEGs of at most 1568 px. */
const MAX_IMAGES = 4;
const MAX_IMAGE_BYTES = 1_500_000;
/** What an image may be, and the base64 its bytes start with, so a mislabelled file is refused. */
const IMAGE_STARTS = { "image/jpeg": "/9j/", "image/png": "iVBORw0KGgo" } as const;
type ImageType = keyof typeof IMAGE_STARTS;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const CHAT_ID = /^fb_[0-9a-f]{16}$/;
const MESSAGE_ID = /^m_[0-9a-f]{16}$/;
/** The runner says it is alive on every poll; quieter than this, the builder is offline. */
const RUNNER_FRESH_MS = 90_000;
/** A claimed message the runner never reported on: it stopped mid-delivery, and the message is not sent again. */
const DELIVERY_STUCK_MS = 15 * 60_000;
const MAX_AGENT_MESSAGES = 500;
const MAX_AGENT_TEXT = 20_000;

const LIST_KEY = "feedback/chats.json";
const RUNNER_KEY = "feedback/runner.json";
const PENDING_PREFIX = "feedback/pending/";
const chatPrefix = (chat: string) => `feedback/chats/${chat}/`;
const messageKey = (chat: string, message: StoredMessage) => `${chatPrefix(chat)}m/${message.at}-${message.id}.json`;
const imageKey = (chat: string, message: string, index: number) => `${chatPrefix(chat)}img/${message}/${index}.json`;
const agentKey = (chat: string) => `${chatPrefix(chat)}agent.json`;
const pendingKey = (chat: string, message: StoredMessage) => `${PENDING_PREFIX}${message.at}-${chat}-${message.id}`;

export interface FeedbackThread {
  id: string;
  title: string;
  createdAt: string;
}

export interface FeedbackImage {
  media_type: ImageType;
  /** The bytes in base64. */
  data: string;
}

export interface FeedbackInput {
  text: string;
  /** The app's build, so the agent knows what Jai was looking at. */
  build: string | null;
  images: FeedbackImage[];
}

type MessageStatus = "pending" | "delivering" | "delivered" | "failed";

/** One of Jai's messages, as kept. Only the app's POST writes a new one; only the runner's claim and result change it. */
interface StoredMessage {
  id: string;
  /** Epoch ms when the Worker took it: orders the chat and the queue. */
  at: number;
  text: string;
  build: string | null;
  images: number;
  /** The chat's first message starts the agent; every other one is told to it. */
  first: boolean;
  status: MessageStatus;
  /** When the runner claimed it. */
  claimedAt: number | null;
  /** Why it was not delivered. */
  detail: string | null;
}

/** The agent's side of a chat, written only by the runner. */
export interface AgentSide {
  messages: Array<{ id: string; text: string; at: string | null }>;
  isWorking: boolean;
  activity: string | null;
  /** Where the agent runs, as the runner names it: its Agents thread, so the app can link the two. */
  thread: { host: string; id: string } | null;
  updatedAt: number;
}

/** A message of the chat, with how many screenshots Jai sent on it. */
export interface FeedbackMessage extends AskMessage {
  images: number;
}

export interface FeedbackChat extends AskChat {
  messages: FeedbackMessage[];
  id: string;
  /** Whether the runner is taking work and the Mac it starts agents on answers. Without it a message waits here. */
  builderOnline: boolean;
  thread: AgentSide["thread"];
}

/** What a runner poll answers: Jai's messages it has not taken, oldest first. */
export interface RunnerWork {
  chat: string;
  message: string;
  first: boolean;
  at: number;
}

/** The little of R2 this needs, so a test can stand in for it. `put` with an etag writes only over that version. */
export interface FeedbackStore {
  get<T>(key: string): Promise<{ value: T; etag: string } | null>;
  put(key: string, value: unknown, ifEtag?: string): Promise<boolean>;
  list(prefix: string): Promise<string[]>;
  delete(key: string): Promise<void>;
}

export function r2Store(bucket: R2Bucket): FeedbackStore {
  return {
    async get<T>(key: string) {
      const object = await bucket.get(key);
      return object ? { value: await object.json<T>(), etag: object.etag } : null;
    },
    async put(key, value, ifEtag) {
      const body = JSON.stringify(value);
      const written = await bucket.put(key, body, ifEtag ? { onlyIf: { etagMatches: ifEtag } } : undefined);
      return written !== null;
    },
    async list(prefix) {
      const keys: string[] = [];
      let cursor: string | undefined;
      do {
        const page = await bucket.list({ prefix, cursor });
        keys.push(...page.objects.map((object) => object.key));
        cursor = page.truncated ? page.cursor : undefined;
      } while (cursor);
      return keys;
    },
    async delete(key) {
      await bucket.delete(key);
    },
  };
}

export function isFeedbackId(id: string): boolean {
  return CHAT_ID.test(id);
}

function newId(prefix: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  return `${prefix}_${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

/** Words, screenshots or both; `null` for anything the agent should not get. */
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

export function titleOf(text: string): string {
  if (!text.trim()) {
    return "Screenshot";
  }
  const line = text.split("\n")[0].trim();
  return line.length > 60 ? `${line.slice(0, 59)}…` : line;
}

async function threads(store: FeedbackStore): Promise<FeedbackThread[]> {
  return (await store.get<FeedbackThread[]>(LIST_KEY))?.value ?? [];
}

/** The runner's last poll, as it left it: when, whether its Mac's Orca answered, and why not. */
interface RunnerBeat {
  at: number;
  orca: boolean;
  detail?: string | null;
}

/** Whether the builder is taking work, and why not: the runner's last poll and what it said about its Mac. */
export interface BuilderStatus {
  online: boolean;
  /** When the runner last polled, ISO 8601; null when it never has. */
  lastPollAt: string | null;
  /** Why it is offline, in a few words; null when it is online. */
  detail: string | null;
}

export function builderStatusOf(beat: RunnerBeat | null, now: number): BuilderStatus {
  if (!beat) {
    return { online: false, lastPollAt: null, detail: "The runner has never polled." };
  }
  const fresh = now - beat.at < RUNNER_FRESH_MS;
  const online = fresh && beat.orca;
  const detail = online ? null
    : !fresh ? `The runner has not polled for ${Math.round((now - beat.at) / 1000)} s.`
    : beat.detail || "The runner's Mac did not answer.";
  return { online, lastPollAt: new Date(beat.at).toISOString(), detail };
}

async function builderStatus(store: FeedbackStore, now: number): Promise<BuilderStatus> {
  return builderStatusOf((await store.get<RunnerBeat>(RUNNER_KEY))?.value ?? null, now);
}

async function builderOnline(store: FeedbackStore, now: number): Promise<boolean> {
  return (await builderStatus(store, now)).online;
}

export async function feedbackList(store: FeedbackStore, now: number) {
  const [list, status] = await Promise.all([threads(store), builderStatus(store, now)]);
  return { threads: list, builderOnline: status.online, builderStatus: status };
}

/** The one log line a list read leaves (`feedback_list_served`): what the app was told about the builder, and why. */
export function listServedLog(status: BuilderStatus, threadCount: number, now: number): string {
  const age = status.lastPollAt === null ? null : Math.round((now - Date.parse(status.lastPollAt)) / 1000);
  return JSON.stringify({
    event: "feedback_list_served", builderOnline: status.online, runnerPollAgeSeconds: age, detail: status.detail,
    threads: threadCount,
  });
}

async function messagesOf(store: FeedbackStore, chat: string): Promise<Array<{ key: string; message: StoredMessage; etag: string }>> {
  const keys = (await store.list(`${chatPrefix(chat)}m/`)).sort();
  const found = await Promise.all(keys.map(async (key) => {
    const got = await store.get<StoredMessage>(key);
    return got ? { key, message: got.value, etag: got.etag } : null;
  }));
  return found.filter((one) => one !== null);
}

/** What the chat says of a message the runner took and never reported on. */
function effectiveStatus(message: StoredMessage, now: number): { status: MessageStatus; detail: string | null } {
  if (message.status === "delivering" && message.claimedAt !== null && now - message.claimedAt > DELIVERY_STUCK_MS) {
    return { status: "failed", detail: "The builder stopped while passing this on. Check the chat before sending again." };
  }
  return { status: message.status, detail: message.detail };
}

/** Null for a chat that does not exist. */
export async function feedbackChat(store: FeedbackStore, chat: string, now: number): Promise<FeedbackChat | null> {
  const [mine, agent, online] = await Promise.all([
    messagesOf(store, chat), store.get<AgentSide>(agentKey(chat)), builderOnline(store, now),
  ]);
  if (mine.length === 0) {
    return null;
  }
  return chatView(chat, mine.map(({ message }) => message), agent?.value ?? null, online, now);
}

/** Jai's messages and the agent's, in time order; working from a send until the agent's turn is over. */
export function chatView(
  id: string, mine: StoredMessage[], agent: AgentSide | null, online: boolean, now: number,
): FeedbackChat {
  const entries: Array<{ at: number; message: FeedbackMessage }> = mine.map((message) => ({
    at: message.at, message: { id: message.id, role: "you", text: message.text, anchor: null, images: message.images },
  }));
  for (const message of agent?.messages ?? []) {
    entries.push({
      at: message.at ? Date.parse(message.at) : now,
      message: { id: message.id, role: "agent", text: message.text, anchor: null, images: 0 },
    });
  }
  entries.sort((a, b) => a.at - b.at);
  const statuses = mine.map((message) => ({ message, ...effectiveStatus(message, now) }));
  const waiting = statuses.some(({ status }) => status === "pending" || status === "delivering");
  // Delivered after the runner last looked: the agent's turn has started, whatever the last look said.
  const unseen = statuses.some(({ message, status }) => status === "delivered" && (agent?.updatedAt ?? 0) < message.at);
  const last = statuses.at(-1);
  const problem = last?.status === "failed" ? last.detail ?? "This message could not be passed on." : null;
  const isWorking = problem === null && (waiting || unseen || (agent?.isWorking ?? false));
  const activity = !isWorking ? null
    : waiting ? (online ? "Starting" : null)
    : agent?.activity ?? "Working";
  return {
    id, messages: entries.map(({ message }) => message), isWorking, activity, problem, costCents: null,
    model: null, effort: null, builderOnline: online, thread: agent?.thread ?? null,
  };
}

/** A message from Jai: a new chat when `chat` is null, else the next in that chat. Null: no such chat. */
export async function addFeedback(
  store: FeedbackStore, chat: string | null, input: FeedbackInput, now: number,
): Promise<string | null> {
  const id = chat ?? newId("fb");
  if (chat && (await store.list(`${chatPrefix(chat)}m/`)).length === 0) {
    return null;
  }
  const message: StoredMessage = {
    id: newId("m"), at: now, text: input.text, build: input.build, images: input.images.length, first: chat === null,
    status: "pending", claimedAt: null, detail: null,
  };
  await Promise.all(input.images.map((image, index) => store.put(imageKey(id, message.id, index), image)));
  await store.put(messageKey(id, message), message);
  await store.put(pendingKey(id, message), { chat: id, message: message.id });
  if (chat === null) {
    const list = await threads(store);
    await store.put(LIST_KEY, [{ id, title: titleOf(input.text), createdAt: new Date(now).toISOString() }, ...list]);
  }
  return id;
}

// --- The runner ------------------------------------------------------------------------------------------------------

/** A poll: the runner is alive (and whether its Mac answers), and the messages it has not taken. */
export async function runnerPoll(
  store: FeedbackStore, orca: boolean, now: number, detail: string | null = null,
): Promise<RunnerWork[]> {
  await store.put(RUNNER_KEY, { at: now, orca, detail: orca ? null : detail?.slice(0, 200) ?? null });
  const keys = (await store.list(PENDING_PREFIX)).sort();
  const work = await Promise.all(keys.map(async (key) => {
    const marker = (await store.get<{ chat: string; message: string }>(key))?.value;
    const found = marker ? await findMessage(store, marker.chat, marker.message) : null;
    if (!found || found.message.status !== "pending") {
      await store.delete(key);
      return null;
    }
    return { chat: marker!.chat, message: found.message.id, first: found.message.first, at: found.message.at };
  }));
  return work.filter((one) => one !== null);
}

async function findMessage(store: FeedbackStore, chat: string, id: string) {
  if (!CHAT_ID.test(chat) || !MESSAGE_ID.test(id)) {
    return null;
  }
  return (await messagesOf(store, chat)).find(({ message }) => message.id === id) ?? null;
}

export type ClaimAnswer =
  | { ok: true; text: string; build: string | null; first: boolean; images: FeedbackImage[]; title: string }
  | { ok: false; status: 404 | 409 };

/** Pending → delivering, once: a second claim, or one racing it, is refused. Answers what the agent is to be told. */
export async function runnerClaim(store: FeedbackStore, chat: string, id: string, now: number): Promise<ClaimAnswer> {
  const found = await findMessage(store, chat, id);
  if (!found) {
    return { ok: false, status: 404 };
  }
  if (found.message.status !== "pending") {
    return { ok: false, status: 409 };
  }
  const claimed: StoredMessage = { ...found.message, status: "delivering", claimedAt: now };
  if (!(await store.put(found.key, claimed, found.etag))) {
    return { ok: false, status: 409 };
  }
  await store.delete(pendingKey(chat, found.message));
  const images = await Promise.all(Array.from({ length: found.message.images }, async (_, index) =>
    (await store.get<FeedbackImage>(imageKey(chat, id, index)))?.value));
  const title = (await threads(store)).find((thread) => thread.id === chat)?.title ?? titleOf(found.message.text);
  return {
    ok: true, text: found.message.text, build: found.message.build, first: found.message.first,
    images: images.filter((image) => image !== undefined), title,
  };
}

/** Delivering → delivered or failed. */
export async function runnerResult(
  store: FeedbackStore, chat: string, id: string, delivered: boolean, detail: string | null,
): Promise<404 | 409 | 200> {
  const found = await findMessage(store, chat, id);
  if (!found) {
    return 404;
  }
  if (found.message.status !== "delivering") {
    return 409;
  }
  const done: StoredMessage = { ...found.message, status: delivered ? "delivered" : "failed", detail: delivered ? null : detail };
  return (await store.put(found.key, done, found.etag)) ? 200 : 409;
}

/** The runner's look at the agent: its messages so far, whether it is working, and where it runs. */
export function parseAgentSide(body: unknown, now: number): AgentSide | null {
  const { messages, isWorking, activity, thread } = (body ?? {}) as Record<string, unknown>;
  if (!Array.isArray(messages) || messages.length > MAX_AGENT_MESSAGES || typeof isWorking !== "boolean"
    || (activity !== null && (typeof activity !== "string" || activity.length > 80))) {
    return null;
  }
  const parsed: AgentSide["messages"] = [];
  for (const item of messages) {
    const { id, text, at } = (item ?? {}) as Record<string, unknown>;
    if (typeof id !== "string" || id.length < 1 || id.length > 200 || typeof text !== "string"
      || text.length > MAX_AGENT_TEXT || (at !== null && (typeof at !== "string" || Number.isNaN(Date.parse(at))))) {
      return null;
    }
    parsed.push({ id, text, at: at as string | null });
  }
  const place = thread as { host?: unknown; id?: unknown } | null | undefined;
  const where = place && typeof place.host === "string" && typeof place.id === "string"
    && place.host.length <= 100 && place.id.length <= 200 ? { host: place.host, id: place.id } : null;
  return { messages: parsed, isWorking, activity: activity as string | null, thread: where, updatedAt: now };
}

export async function runnerAgent(store: FeedbackStore, chat: string, agent: AgentSide): Promise<404 | 200> {
  if (!CHAT_ID.test(chat) || (await store.list(`${chatPrefix(chat)}m/`)).length === 0) {
    return 404;
  }
  await store.put(agentKey(chat), agent);
  return 200;
}
