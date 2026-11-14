// The Agent SDK container's Durable Object (`agent-container.ts` calls it). Apart, so tests never load the runtime.
import { Container } from "@cloudflare/containers";
import type { StopParams } from "@cloudflare/containers";
import { errorWords } from "./ask-trace.ts";
import type { Env } from "./env.ts";

/** The container that runs the Agent SDK. Asleep after two idle minutes, so a quiet day costs nothing. */
export class AgentContainer extends Container<Env> {
  override defaultPort = 8080;
  override sleepAfter = "2m";

  constructor(ctx: DurableObjectState<{}>, env: Env) {
    super(ctx, env);
    this.envVars = { CLAUDE_CODE_OAUTH_TOKEN: env.CLAUDE_CODE_OAUTH_TOKEN ?? "" };
  }

  /** Why the container failed, as an event: its alarms and starts otherwise throw with nothing said. */
  override onError(error: unknown): unknown {
    console.error("agent_container_error", { reason: errorWords(error) });
    throw error;
  }

  /** Each stop, and why: a sleep, a deploy's new code, or a crash (`exitCode`). */
  override onStop(params: StopParams): void {
    console.log("agent_container_stopped", params);
  }
}
