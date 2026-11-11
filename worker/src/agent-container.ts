// AI on a subscription (docs/api.md, "AI on a subscription"): key lines and rewrites run in a container with the Claude
// Agent SDK (`agent/`), signed in with CLAUDE_CODE_OAUTH_TOKEN, instead of on an API key.
import { type Env, isSet } from "./env.ts";
import type { Effort, ModelChoice } from "./models.ts";

/** Whether AI runs on the subscription: a token, and the container to run it in. */
export function onSubscription(env: Pick<Env, "CLAUDE_CODE_OAUTH_TOKEN" | "AGENT">): boolean {
  return isSet(env.CLAUDE_CODE_OAUTH_TOKEN) && env.AGENT !== undefined;
}

/** Whether key lines and rewrites can run at all: on the subscription, or on an API key. */
export function makesAnswers(env: Pick<Env, "CLAUDE_CODE_OAUTH_TOKEN" | "AGENT" | "ANTHROPIC_API_KEY">): boolean {
  return onSubscription(env) || isSet(env.ANTHROPIC_API_KEY);
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
export const CONTAINER_TRIES = 3;
const RETRY_AFTER_MS = 5_000;

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * The container's JSON answer. Cloudflare's own words when no instance is ready, and a run whose Claude Code was stopped
 * under it (exit 143), go again after a pause, up to `CONTAINER_TRIES` tries.
 */
export async function askContainer<Answer extends { error?: string }>(
  path: "/run" | "/ask", body: string, agent: NonNullable<Env["AGENT"]>, wait: (ms: number) => Promise<void> = pause,
): Promise<Answer> {
  let failure = "";
  for (let tryNumber = 1; tryNumber <= CONTAINER_TRIES; tryNumber++) {
    const response = await agent.get(agent.idFromName("ai")).fetch(`http://agent${path}`, {
      method: "POST", headers: { "content-type": "application/json" }, body,
    });
    const text = await response.text();
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
  system: string, prompt: string, schema: Record<string, unknown>, choice: ModelChoice, env: Env, wait = pause,
): Promise<AgentAnswer> {
  const body = { system, prompt, model: choice.model, effort: choice.effort satisfies Effort, schema };
  const answer = await askContainer<ContainerAnswer>("/run", JSON.stringify(body), env.AGENT!, wait);
  if (answer.error) {
    throw new Error(`The AI container failed: ${answer.error}`);
  }
  if (answer.subtype !== "success" || answer.output === null || answer.output === undefined) {
    throw new Error("The model's answer was cut off.");
  }
  return answer as AgentAnswer;
}
