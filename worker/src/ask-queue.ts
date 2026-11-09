/**
 * Questions to a PR's Ask agent, kept by the Worker until the agent has them. Starting or waking a session, minting its
 * GitHub token and sending the question take seconds, so `POST …/ask` only stores the question here and answers `202`;
 * an `AiJobs` object of its own (`askQueue`) hands each question to the agent from its alarm, one at a time, in order.
 * Until the agent has it, and when it could not be handed over, the chat shows it from here (`withQueued`). The SQL runs
 * on a Durable Object's SQLite; a test passes `node:sqlite` behind the same shape.
 */
import { type AskChat, type AskInput, chatOf } from "./ask-chat.ts";
import type { LimitSql } from "./limit-counter.ts";
import type { RepoFullName } from "./ids.ts";
import type { ModelChoice } from "./models.ts";

export interface QueuedAsk {
  /** The phone's `client_ref`, so a repeat is the question already here; else one the Worker made. */
  id: string;
  repo: RepoFullName;
  number: number;
  input: AskInput;
  choice: ModelChoice;
  at: number;
  /** Why the agent never got it. A new question to the same PR clears it. */
  error: string | null;
}

/** What the phone sees at once: the chat as last read, and the questions the agent doesn't have yet. */
export interface AskView {
  chat: AskChat | null;
  queued: QueuedAsk[];
}

/** Longer than any handover takes: a question still here after this was never handed over, and says so. */
export const ASK_HANDOVER_MS = 2 * 60_000;
export const NOT_HANDED_OVER = "The question didn't reach the AI. Try again.";
const KEPT_MS = 7 * 24 * 60 * 60_000;

export function askPr(repo: string, number: number): string {
  return `${repo}#${number}`;
}

export function createAskTables(sql: LimitSql): void {
  sql.exec(`CREATE TABLE IF NOT EXISTS asks (id TEXT PRIMARY KEY, pr TEXT, ask TEXT, at INTEGER, error TEXT)`);
  sql.exec(`CREATE TABLE IF NOT EXISTS ask_chats (pr TEXT PRIMARY KEY, chat TEXT, at INTEGER)`);
}

/** A question in. A failed one before it on the same PR goes: this is its Try again, or a new question. */
export function queueAsk(sql: LimitSql, ask: QueuedAsk): void {
  const pr = askPr(ask.repo, ask.number);
  sql.exec("DELETE FROM asks WHERE (pr = ? AND error IS NOT NULL) OR at < ?", pr, ask.at - KEPT_MS);
  sql.exec("DELETE FROM ask_chats WHERE at < ?", ask.at - KEPT_MS);
  sql.exec("INSERT OR IGNORE INTO asks (id, pr, ask, at, error) VALUES (?, ?, ?, ?, NULL)",
    ask.id, pr, JSON.stringify(ask), ask.at);
}

/** The oldest question not yet handed over and not failed. */
export function nextAsk(sql: LimitSql): QueuedAsk | null {
  const row = sql.exec<{ ask: string; error: string | null }>(
    "SELECT ask, error FROM asks WHERE error IS NULL ORDER BY at, id LIMIT 1").toArray()[0];
  return row ? queuedOf(row) : null;
}

/** Handed over: it goes. Not: it stays, with why, for the chat to show. */
export function finishAsk(sql: LimitSql, id: string, error: string | null): void {
  if (error === null) {
    sql.exec("DELETE FROM asks WHERE id = ?", id);
    return;
  }
  sql.exec("UPDATE asks SET error = ? WHERE id = ?", error, id);
}

function queuedOf(row: { ask: string; error: string | null }): QueuedAsk {
  return { ...JSON.parse(row.ask) as QueuedAsk, error: row.error };
}

/** Every question here, one at a time and in order: one handover must end before the next, or two could start sessions. */
export async function drainAsks(sql: LimitSql, handOver: (ask: QueuedAsk) => Promise<string | null>): Promise<void> {
  for (let ask = nextAsk(sql); ask; ask = nextAsk(sql)) {
    finishAsk(sql, ask.id, await handOver(ask));
  }
}

/** The chat as `GET …/ask` last read it, for the next `POST` to answer with at once. */
export function rememberChat(sql: LimitSql, pr: string, chat: AskChat, now: number): void {
  sql.exec(`INSERT INTO ask_chats (pr, chat, at) VALUES (?, ?, ?)
    ON CONFLICT (pr) DO UPDATE SET chat = excluded.chat, at = excluded.at`, pr, JSON.stringify(chat), now);
}

export function askView(sql: LimitSql, pr: string): AskView {
  const chat = sql.exec<{ chat: string }>("SELECT chat FROM ask_chats WHERE pr = ?", pr).toArray()[0];
  const queued = sql.exec<{ ask: string; error: string | null }>(
    "SELECT ask, error FROM asks WHERE pr = ? ORDER BY at, id", pr).toArray();
  return { chat: chat ? JSON.parse(chat.chat) as AskChat : null, queued: queued.map(queuedOf) };
}

/**
 * The chat with the questions the agent doesn't have yet at its end, as working, or a failed one with why. A question the
 * chat already ends with was handed over a moment ago: it isn't shown twice.
 */
export function withQueued(chat: AskChat | null, queued: readonly QueuedAsk[], now: number): AskChat {
  let shown = chat ?? chatOf([], null);
  for (const ask of queued) {
    const asked = shown.messages.filter((message) => message.role === "you").at(-1);
    const handedOver = asked?.text === ask.input.question;
    if (!handedOver) {
      const anchor = ask.input.anchor ? `${ask.input.anchor.path}:${ask.input.anchor.line}` : null;
      shown = { ...shown, messages: [...shown.messages, { id: `queued:${ask.id}`, role: "you", text: ask.input.question, anchor }] };
    }
    const problem = ask.error ?? (now - ask.at > ASK_HANDOVER_MS ? NOT_HANDED_OVER : null);
    if (problem) {
      shown = { ...shown, isWorking: false, activity: null, problem };
    } else if (!handedOver) {
      shown = { ...shown, isWorking: true, activity: null, problem: null };
    }
  }
  return shown;
}

/** What a `POST …/ask` needs, so it answers once the question is stored and never waits on GitHub or the agent. */
export interface AskIntake {
  claim(receipt: string): Promise<"go" | "busy" | "done">;
  finish(receipt: string, sent: boolean): Promise<void>;
  /** A limit's refusal, or null when the question may go. */
  limited(receipt: string | null): Promise<Response | null>;
  /** Stores the question (null: a repeat, nothing to store) and answers what the phone should see. */
  queue(ask: QueuedAsk | null): Promise<AskView>;
  busy(): Response;
}

/** `202` with the chat and the question in it, or the refusal. `receipt` is `ask:<pr>:<client_ref>` when there is one. */
export async function acceptAsk(intake: AskIntake, ask: QueuedAsk, receipt: string | null): Promise<Response> {
  const claim = receipt ? await intake.claim(receipt) : "go";
  if (claim === "busy") {
    return intake.busy();
  }
  if (claim === "go") {
    const limited = await intake.limited(receipt);
    if (limited) {
      if (receipt) {
        await intake.finish(receipt, false);
      }
      return limited;
    }
  }
  const view = await intake.queue(claim === "go" ? ask : null);
  if (receipt && claim === "go") {
    await intake.finish(receipt, true);
  }
  return Response.json(withQueued(view.chat, view.queued, ask.at), { status: 202 });
}
