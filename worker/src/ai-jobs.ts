import { DurableObject } from "cloudflare:workers";
import { aiStoreKey, runAiJob } from "./ai-run";
import { actingEnvFor } from "./hosted";
import { parseAiJob } from "./boundary";
import { prId } from "./ids";
import { type Env, prIndex } from "./env";
import { type AiJob, aiKey } from "./models";

export { type AiJob, aiKey };

const JOBS_AT_ONCE = 2;

/**
 * Model calls take a minute, so they run here, apart from `PrIndex`: its alarm is what keeps PRs fresh, and it must never
 * wait on one. An answer or a failure lands in R2 under `aiKey`; a failure can be asked for again. On the hosted Worker
 * each person has their own (`user:<id>`), and its jobs run as that person: their GitHub token, their Anthropic key,
 * their R2 prefix.
 */
export class AiJobs extends DurableObject<Env> {
  private readonly sql = this.ctx.storage.sql;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql.exec("CREATE TABLE IF NOT EXISTS jobs (key TEXT PRIMARY KEY, job TEXT)");
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

  /** Delete Account: no queued job runs, or stores an answer, for a person who is gone. */
  async forget(): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    // This object may serve the same id again before it is evicted: a person who deletes and signs in again.
    this.sql.exec("CREATE TABLE IF NOT EXISTS jobs (key TEXT PRIMARY KEY, job TEXT)");
  }

  override async alarm(): Promise<void> {
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

  private async run(job: AiJob): Promise<void> {
    const userId = await this.ctx.storage.get<string>("user_id");
    // A hosted person with no token or key now (signed out, or the key removed) runs nothing: never on anyone else's.
    const env = userId ? await actingEnvFor(this.env, userId).catch(() => null) : this.env;
    if (!env || !env.ANTHROPIC_API_KEY) {
      await this.env.DIFFS.put(aiStoreKey(job, { SIGNED_IN_USER_ID: userId }),
        JSON.stringify({ error: "Sign in and set your Anthropic key to use AI." }));
      return;
    }
    if (await runAiJob(job, env, env.DIFFS)) {
      await prIndex(env).keyLinesReady(prId(job.repo, job.number), job.head);
    }
  }
}
