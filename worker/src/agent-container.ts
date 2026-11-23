// AI on a subscription (docs/api.md, "AI on a subscription"): key lines and rewrites run in a container with the Claude
// Agent SDK (`agent/`), signed in with CLAUDE_CODE_OAUTH_TOKEN, instead of on an API key.
import { scrubbed } from "./ask-trace.ts";
import { type Env, isSet } from "./env.ts";
import type { Effort, ModelChoice } from "./models.ts";

/**
 * The subscription's Claude accounts: `CLAUDE_CODE_OAUTH_TOKEN` holds one token, or several separated by commas or new
 * lines. The container reads the same secret and runs each turn on the account the Worker names (`account`, an index).
 */
export function subscriptionAccounts(env: Pick<Env, "CLAUDE_CODE_OAUTH_TOKEN">): number {
  return (env.CLAUDE_CODE_OAUTH_TOKEN ?? "").split(/[\s,]+/).filter(Boolean).length;
}

/** What Claude Code says when an account can't run now: its usage limit, or a token it no longer takes. */
export const ACCOUNT_SPENT =
  /hit your .*limit|usage limit|weekly limit|limit reached|resets .*\(UTC\)|rate.?limit|\b429\b|credit balance|invalid.*(token|api key)|oauth token|authentication|\b401\b/i;

/** The account the next run starts on, in this isolate: one that hit its limit is passed over until the rest have too. */
let currentAccount = 0;

/** For tests: start again on the first account. */
export function resetAccounts(): void {
  currentAccount = 0;
}

/** Whether AI runs on the subscription: a token, and the container to run it in. */
export function onSubscription(env: Pick<Env, "CLAUDE_CODE_OAUTH_TOKEN" | "AGENT">): boolean {
  return isSet(env.CLAUDE_CODE_OAUTH_TOKEN) && env.AGENT !== undefined;
}

/** Whether key lines and rewrites can run at all: on the subscription, or on an API key. */
export function makesAnswers(
  env: Pick<Env, "CLAUDE_CODE_OAUTH_TOKEN" | "AGENT" | "ANTHROPIC_API_KEY" | "AI_ON_API_KEY">,
): boolean {
  return onSubscription(env) || (onApiKey(env) && isSet(env.ANTHROPIC_API_KEY));
}

/** Whether AI may run on an Anthropic API key at all: off unless `AI_ON_API_KEY` is `on`, while AI is on the subscription. */
export function onApiKey(env: Pick<Env, "AI_ON_API_KEY">): boolean {
  return env.AI_ON_API_KEY?.trim() === "on";
}

export interface AgentAnswer {
  output: unknown;
  model: string;
  tokens: { input: number; output: number };
  /** What the run would have cost on the API; the subscription is billed by plan, not by run. */
  costUsd: number | null;
}

type ContainerAnswer = Partial<AgentAnswer> & { error?: string; subtype?: string };

/** Tries a run takes before it fails: a container that is starting, stopping or full answers without JSON. */
export const CONTAINER_TRIES = 4;
const RETRY_AFTER_MS = 5_000;

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * The container's JSON answer, on the subscription's accounts in turn: a run that one account can't make (its limit, a
 * token it no longer takes, `ACCOUNT_SPENT`) goes again on the next, until each has been tried once. The account that
 * answered is where the next run starts.
 */
export async function askContainer<Answer extends { error?: string }>(
  path: "/run" | "/ask",
  body: Record<string, unknown>,
  env: Pick<Env, "AGENT" | "CLAUDE_CODE_OAUTH_TOKEN">,
  wait: (ms: number) => Promise<void> = pause,
  instance = "ai",
  doing?: (activity: string) => void,
): Promise<Answer> {
  const accounts = Math.max(1, subscriptionAccounts(env));
  const first = currentAccount % accounts;
  let answer = { error: "No account answered." } as Answer;
  for (let tried = 0; tried < accounts; tried++) {
    const account = (first + tried) % accounts;
    answer = await onContainer<Answer>(
      path,
      JSON.stringify({ ...body, account, ...(doing ? { progress: true } : {}) }),
      env.AGENT!,
      wait,
      instance,
      doing,
    );
    if (!answer.error || !ACCOUNT_SPENT.test(answer.error)) {
      currentAccount = account;
      return answer;
    }
    console.warn("agent_account_spent", {
      account,
      of: accounts,
      path,
      reason: scrubbed(answer.error),
    });
    currentAccount = account + 1;
  }
  return answer;
}

const ACTIVITY_LENGTH = 80;

/**
 * The answer's text. A container asked for `progress` answers in lines (`application/x-ndjson`): `{"activity"}` as the
 * agent works, the answer last. One from before that answers the JSON alone.
 */
export async function answerText(
  response: Response,
  doing?: (activity: string) => void,
): Promise<string> {
  if (!response.headers.get("content-type")?.startsWith("application/x-ndjson") || !response.body) {
    return response.text();
  }
  let rest = "";
  const hear = (line: string) => {
    const said = activityIn(line);
    if (said === null) {
      return false;
    }
    doing?.(said);
    return true;
  };
  for await (const chunk of response.body.pipeThrough(new TextDecoderStream())) {
    const lines = (rest + chunk).split("\n");
    rest = lines.pop() ?? "";
    for (const line of lines) {
      if (!hear(line)) {
        return line;
      }
    }
  }
  return hear(rest) ? "" : rest;
}

/** A line's activity; null for the answer's own line. */
function activityIn(line: string): string | null {
  try {
    const { activity } = JSON.parse(line) as { activity?: unknown };
    return typeof activity === "string" ? scrubbed(activity).slice(0, ACTIVITY_LENGTH) : null;
  } catch {
    return null;
  }
}

/**
 * One run's JSON answer. Cloudflare's own words when no instance is ready, and a run whose Claude Code was stopped
 * under it (exit 143), go again after a pause, up to `CONTAINER_TRIES` tries.
 */
async function onContainer<Answer extends { error?: string }>(
  path: "/run" | "/ask",
  body: string,
  agent: NonNullable<Env["AGENT"]>,
  wait: (ms: number) => Promise<void>,
  instance: string,
  doing?: (activity: string) => void,
): Promise<Answer> {
  let failure = "";
  for (let tryNumber = 1; tryNumber <= CONTAINER_TRIES; tryNumber++) {
    let response: Response;
    let text: string;
    try {
      response = await agent.get(agent.idFromName(instance)).fetch(`http://agent${path}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
      });
      text = await answerText(response, doing);
    } catch (error) {
      // The container went away mid-run, as a deploy replaces it: the run goes again in a new one.
      failure = String(error instanceof Error ? error.message : error);
      if (tryNumber < CONTAINER_TRIES) {
        await wait(RETRY_AFTER_MS);
      }
      continue;
    }
    let answer: Answer | null = null;
    try {
      answer = JSON.parse(text) as Answer;
    } catch {
      failure = text.slice(0, 200) || `HTTP ${response.status}`;
    }
    if (answer && !(answer.error ?? "").includes("code 143")) {
      return answer;
    }
    failure = answer?.error ?? failure;
    if (tryNumber < CONTAINER_TRIES) {
      await wait(RETRY_AFTER_MS);
    }
  }
  return { error: failure } as Answer;
}

/** One structured answer from the container. Throws with the container's own words when it fails. */
export async function runOnSubscription(
  system: string,
  prompt: string,
  schema: Record<string, unknown>,
  choice: ModelChoice,
  env: Env,
  wait = pause,
): Promise<AgentAnswer> {
  const body = {
    system,
    prompt,
    model: choice.model,
    effort: choice.effort satisfies Effort,
    schema,
  };
  const answer = await askContainer<ContainerAnswer>("/run", body, env, wait);
  if (answer.error) {
    console.error("agent_container_failed", {
      path: "/run",
      model: choice.model,
      reason: scrubbed(answer.error),
    });
    throw new Error(`The AI container failed: ${answer.error}`);
  }
  if (answer.subtype !== "success" || answer.output === null || answer.output === undefined) {
    throw new Error("The model's answer was cut off.");
  }
  return answer as AgentAnswer;
}
