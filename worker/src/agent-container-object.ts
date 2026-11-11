// The Agent SDK container's Durable Object (`agent-container.ts` calls it). Apart, so tests never load the runtime.
import { Container } from "@cloudflare/containers";
import type { Env } from "./env.ts";

/** The container that runs the Agent SDK. Asleep after two idle minutes, so a quiet day costs nothing. */
export class AgentContainer extends Container<Env> {
  override defaultPort = 8080;
  override sleepAfter = "2m";

  constructor(ctx: DurableObjectState<{}>, env: Env) {
    super(ctx, env);
    this.envVars = { CLAUDE_CODE_OAUTH_TOKEN: env.CLAUDE_CODE_OAUTH_TOKEN ?? "" };
  }
}
