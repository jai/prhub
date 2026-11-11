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

/** One structured answer from the container. Throws with the container's own words when it fails. */
export async function runOnSubscription(
  system: string, prompt: string, schema: Record<string, unknown>, choice: ModelChoice, env: Env,
): Promise<AgentAnswer> {
  const body = { system, prompt, model: choice.model, effort: choice.effort satisfies Effort, schema };
  const agent = env.AGENT!;
  const response = await agent.get(agent.idFromName("ai")).fetch("http://agent/run", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
  });
  const answer = await response.json() as Partial<AgentAnswer> & { error?: string; subtype?: string };
  if (!response.ok || answer.error) {
    throw new Error(`The AI container failed: ${answer.error ?? `HTTP ${response.status}`}`);
  }
  if (answer.subtype !== "success" || answer.output === null || answer.output === undefined) {
    throw new Error("The model's answer was cut off.");
  }
  return answer as AgentAnswer;
}
