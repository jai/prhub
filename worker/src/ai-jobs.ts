import { DurableObject } from "cloudflare:workers";
import { aiStoreKey, runAiJob } from "./ai-run";
import { ask, AskRefused } from "./ask";
import type { AskChat } from "./ask-chat";
import {
  askView, type AskView, createAskTables, drainAsks, type QueuedAsk, queueAsk, rememberChat,
} from "./ask-queue";
import { actingEnvFor } from "./hosted";
import { parseAiJob } from "./boundary";
import { prId } from "./ids";
import { makesAnswers } from "./agent-container";
import { askEvent, errorWords, failedLine, scrubbed, sideOf } from "./ask-trace";
import { type Env, prIndex } from "./env";
import { type AiJob, aiKey } from "./models";
import { type CarriedAskState, readCarriedAskState, writeCarriedAskState } from "./carry";

export { type AiJob, aiKey };

const JOBS_AT_ONCE = 2;

/**
 * Model calls take a minute, so they run here, apart from `PrIndex`: its alarm is what keeps PRs fresh, and it must never
 * wait on one. An answer or a failure lands in R2 under `aiKey`; a failure can be asked for again. On the hosted Worker
 * each person has their own (`user:<id>`), and its jobs run as that person: their GitHub token, their Anthropic key,
 * their R2 prefix.
 *
 * Ask's questions go through an object of their own (`askQueue`), so a question never waits behind a minute-long job:
 * `queueAsk` stores one and its alarm hands it to the agent (`ask-queue.ts`).
 */
export class AiJobs extends DurableObject<Env> {
  private readonly sql = this.ctx.storage.sql;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql.exec("CREATE TABLE IF NOT EXISTS jobs (key TEXT PRIMARY KEY, job TEXT)");
    createAskTables(this.sql);
  }

  /** A question for the agent (null: a repeat, already here), and what the phone should see of the PR's chat now. */
  async queueAsk(question: QueuedAsk | null, pr: string, userId: string | null): Promise<AskView> {
    if (question) {
      if (userId !== null) {
        await this.ctx.storage.put("user_id", userId);
      }
      queueAsk(this.sql, question);
      if (await this.ctx.storage.getAlarm() === null) {
        await this.ctx.storage.setAlarm(Date.now());
      }
    }
    return askView(this.sql, pr);
  }

  /** The chat as just read from the agent, kept for the next question's answer, and the questions it doesn't have yet. */
  async readAsks(pr: string, chat: AskChat): Promise<QueuedAsk[]> {
    rememberChat(this.sql, pr, chat, Date.now());
    return askView(this.sql, pr).queued;
  }

  /** `userId` is the hosted person whose jobs these are; null on a self-hosted Worker. */
  async enqueue(job: AiJob, userId: string | null = null): Promise<void> {
    if (userId !== null) {
      await this.ctx.storage.put("user_id", userId);
    }
    this.sql.exec("INSERT OR IGNORE INTO jobs (key, job) VALUES (?, ?)", aiKey(job), JSON.stringify(job));
    if (await this.ctx.storage.getAlarm() === null) {
      await this.ctx.storage.setAlarm(Date.now());
    }
  }

  /** Ask's queue and chats, for a move to another Worker (`carry.ts`). */
  exportCarried(): CarriedAskState {
    return readCarriedAskState(this.sql);
  }

  /** What `exportCarried` gave on the Worker before, added where missing; a queued question is handed over as usual. */
  async importCarried(state: CarriedAskState): Promise<{ asks: number; askChats: number }> {
    const counts = writeCarriedAskState(this.sql, state);
    if (counts.asks > 0 && await this.ctx.storage.getAlarm() === null) {
      await this.ctx.storage.setAlarm(Date.now());
    }
    return counts;
  }

  /** Delete Account: no queued job runs, or stores an answer, for a person who is gone. */
  async forget(): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    // This object may serve the same id again before it is evicted: a person who deletes and signs in again.
    this.sql.exec("CREATE TABLE IF NOT EXISTS jobs (key TEXT PRIMARY KEY, job TEXT)");
    createAskTables(this.sql);
  }

  override async alarm(): Promise<void> {
    await drainAsks(this.sql, (question) => this.handOver(question));
    const rows = this.sql.exec<{ key: string; job: string }>("SELECT key, job FROM jobs LIMIT ?", JOBS_AT_ONCE).toArray();
    await Promise.all(rows.map(async ({ key, job }) => {
      const parsed = parseAiJob(job);
      if (parsed) {
        await this.run(parsed);
      }
      this.sql.exec("DELETE FROM jobs WHERE key = ?", key);
    }));
    if (this.sql.exec("SELECT 1 FROM jobs LIMIT 1").toArray().length > 0) {
      await this.ctx.storage.setAlarm(Date.now());
    }
  }

  /** Null once the agent has the question, else why it couldn't, in words for the chat. */
  private async handOver(question: QueuedAsk): Promise<string | null> {
    const env = await this.actingEnv();
    if (!env) {
      return "Sign in again to ask.";
    }
    try {
      await ask(question.repo, question.number, question.input, question.choice, env, question.id);
      return null;
    } catch (error) {
      if (error instanceof AskRefused) {
        return error.message;
      }
      console.error("ask failed", errorWords(error), scrubbed(error instanceof Error ? error.stack ?? "" : ""));
      askEvent("failed", question.id, { pr: `${question.repo}#${question.number}`, side: sideOf(error),
        reason: errorWords(error) });
      return failedLine(error, question.id);
    }
  }

  /** This object's person's env on the hosted Worker (null when they have no token now), else the Worker's own. */
  private async actingEnv(): Promise<Env | null> {
    const userId = await this.ctx.storage.get<string>("user_id");
    return userId ? await actingEnvFor(this.env, userId).catch(() => null) : this.env;
  }

  private async run(job: AiJob): Promise<void> {
    const userId = await this.ctx.storage.get<string>("user_id");
    // A hosted person with no token or key now (signed out, or the key removed) runs nothing: never on anyone else's.
    const env = await this.actingEnv();
    if (!env || !makesAnswers(env)) {
      await this.env.DIFFS.put(aiStoreKey(job, { SIGNED_IN_USER_ID: userId }),
        JSON.stringify({ error: "Sign in and set your Anthropic key to use AI." }));
      return;
    }
    if (await runAiJob(job, env, env.DIFFS)) {
      await prIndex(env).keyLinesReady(prId(job.repo, job.number), job.head);
    }
  }
}
