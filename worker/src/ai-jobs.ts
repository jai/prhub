import { DurableObject } from "cloudflare:workers";
import { runAiJob } from "./ai-run";
import { parseAiJob } from "./boundary";
import { prId } from "./ids";
import { type Env, prIndex } from "./env";
import { type AiJob, aiKey } from "./models";

export { type AiJob, aiKey };

const JOBS_AT_ONCE = 2;

/**
 * Model calls take a minute, so they run here, apart from `PrIndex`: its alarm is what keeps PRs fresh, and it must never
 * wait on one. An answer or a failure lands in R2 under `aiKey`; a failure can be asked for again.
 */
export class AiJobs extends DurableObject<Env> {
  private readonly sql = this.ctx.storage.sql;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql.exec("CREATE TABLE IF NOT EXISTS jobs (key TEXT PRIMARY KEY, job TEXT)");
  }

  async enqueue(job: AiJob): Promise<void> {
    this.sql.exec("INSERT OR IGNORE INTO jobs (key, job) VALUES (?, ?)", aiKey(job), JSON.stringify(job));
    if (await this.ctx.storage.getAlarm() === null) {
      await this.ctx.storage.setAlarm(Date.now());
    }
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
    if (await runAiJob(job, this.env, this.env.DIFFS)) {
      await prIndex(this.env).keyLinesReady(prId(job.repo, job.number), job.head);
    }
  }
}
