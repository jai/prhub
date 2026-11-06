import { DurableObject } from "cloudflare:workers";
import { generateKeyLines, generateRewrite } from "./ai";
import { type Env, prIndex } from "./env";
import { DEFAULT_CONTEXT } from "./key-lines";

const JOBS_AT_ONCE = 2;

export interface AiJob {
  kind: "key_lines" | "rewrite";
  repo: string;
  number: number;
  head: string;
  /** Key lines only: lines of code either side of a change. 0 is the diff alone, -1 the whole file. */
  context: number;
}

/** Where a job's answer lands. The commit and the context are in the name, so an answer is good for ever. */
export function aiKey({ kind, repo, number, head, context }: AiJob): string {
  return `ai/${repo}/${number}/${head}/${kind === "key_lines" ? `key-lines-${context}` : "rewrite"}.json`;
}

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
      await this.run(key, JSON.parse(job) as AiJob);
      this.sql.exec("DELETE FROM jobs WHERE key = ?", key);
    }));
    if (this.sql.exec("SELECT 1 FROM jobs LIMIT 1").toArray().length > 0) {
      await this.ctx.storage.setAlarm(Date.now());
    }
  }

  private async run(key: string, job: AiJob): Promise<void> {
    const { repo, number, head, context } = job;
    try {
      const answer = job.kind === "key_lines"
        ? await generateKeyLines(repo, number, head, context, this.env)
        : await generateRewrite(repo, number, head, this.env);
      await this.env.DIFFS.put(key, JSON.stringify(answer));
      if (job.kind === "key_lines" && context === DEFAULT_CONTEXT) {
        await prIndex(this.env).keyLinesReady(`${repo}#${number}`, head);
      }
    } catch (error) {
      await this.env.DIFFS.put(key, JSON.stringify({ error: String(error) }));
    }
  }
}
