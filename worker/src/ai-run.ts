import { generateKeyLines, generateRewrite } from "./ai.ts";
import { aiConfigOf } from "./config.ts";
import { type Env, scopedKey } from "./env.ts";
import { DEFAULT_CONTEXT } from "./key-lines.ts";
import { type AiJob, aiKey, BUILT_IN_DEFAULTS, sameChoice } from "./models.ts";

/**
 * One AI job, its answer or its failure put in R2 under `aiKey`, under the person's prefix on the hosted Worker
 * (`aiStoreKey`), so one person's answers are never another's. An answer is put only when it is of the job's own head:
 * `generateKeyLines` and `generateRewrite` refuse a PR that has moved on. True when the list's key lines are now ready.
 */
export async function runAiJob(job: AiJob, env: Env, store: Pick<R2Bucket, "put">): Promise<boolean> {
  const key = aiStoreKey(job, env);
  const { repo, number, head, context } = job;
  const choice = job.choice ?? BUILT_IN_DEFAULTS[job.kind];
  try {
    const answer = job.kind === "key_lines"
      ? await generateKeyLines(repo, number, head, context, choice, env)
      : await generateRewrite(repo, number, head, choice, env);
    await store.put(key, JSON.stringify(answer));
    return job.kind === "key_lines" && context === DEFAULT_CONTEXT
      && sameChoice(choice, aiConfigOf(env).defaults.key_lines);
  } catch (error) {
    await store.put(key, JSON.stringify({ error: String(error) }));
    return false;
  }
}

/** Where a job's answer is kept for whoever `env` acts as. */
export function aiStoreKey(job: AiJob, env: Pick<Env, "SIGNED_IN_USER_ID">): string {
  return scopedKey(env, aiKey(job));
}

/** How long a failed AI answer is shown before the next ask makes it again: long enough to read, short enough to heal. */
export const FAILURE_KEPT_MS = 10 * 60_000;

/** A stored failure older than `FAILURE_KEPT_MS`: a run out of credit, or a container that was not ready, goes again. */
export function isStaleFailure(body: string, storedAt: Date, now: number): boolean {
  if (now - storedAt.getTime() < FAILURE_KEPT_MS) {
    return false;
  }
  try {
    return typeof (JSON.parse(body) as { error?: unknown }).error === "string";
  } catch {
    return false;
  }
}
