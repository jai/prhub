import { generateKeyLines, generateRewrite } from "./ai.ts";
import { aiConfigOf } from "./config.ts";
import type { Env } from "./env.ts";
import { DEFAULT_CONTEXT } from "./key-lines.ts";
import { type AiJob, aiKey, BUILT_IN_DEFAULTS, sameChoice } from "./models.ts";

/**
 * One AI job, its answer or its failure put in R2 under `aiKey`. An answer is put only when it is of the job's own head:
 * `generateKeyLines` and `generateRewrite` refuse a PR that has moved on. True when the list's key lines are now ready.
 */
export async function runAiJob(job: AiJob, env: Env, store: Pick<R2Bucket, "put">): Promise<boolean> {
  const { repo, number, head, context } = job;
  const choice = job.choice ?? BUILT_IN_DEFAULTS[job.kind];
  try {
    const answer = job.kind === "key_lines"
      ? await generateKeyLines(repo, number, head, context, choice, env)
      : await generateRewrite(repo, number, head, choice, env);
    await store.put(aiKey(job), JSON.stringify(answer));
    return job.kind === "key_lines" && context === DEFAULT_CONTEXT
      && sameChoice(choice, aiConfigOf(env).defaults.key_lines);
  } catch (error) {
    await store.put(aiKey(job), JSON.stringify({ error: String(error) }));
    return false;
  }
}
