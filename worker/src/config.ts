import { pushMode } from "./apns.ts";
import { type Env, isSet } from "./env.ts";

/** `GET /device/config` (docs/api/pr-selfhost.md): what this Worker can serve, so the app shows only that. */
export interface DeviceConfig {
  features: {
    ask_ai: boolean;
    key_lines: boolean;
    rewrite: boolean;
    feedback: boolean;
    push: boolean;
    webhooks: boolean;
  };
  /** Whose PRs these are. Null when GitHub could not be asked. */
  login: string | null;
  /** The owners the app filters to by default, from `GITHUB_ORGS`. Absent when it is unset. */
  orgs?: string[];
}

export function askConfigured(env: Env): boolean {
  return [env.ASK_AGENT_ID, env.ASK_ENVIRONMENT_ID, env.ASK_VAULT_ID, env.ASK_CREDENTIAL_ID].every(isSet)
    && (isSet(env.ASK_ANTHROPIC_API_KEY) || isSet(env.ANTHROPIC_API_KEY));
}

/** Jai's alone: the builder agent changes his app. A self-hosted Worker never sets these. */
export function feedbackConfigured(env: Env): boolean {
  return isSet(env.FEEDBACK_AGENT_ID) && isSet(env.FEEDBACK_ENVIRONMENT_ID) && isSet(env.ASK_ANTHROPIC_API_KEY);
}

/** Each feature is on when what serves it is configured; nothing is a separate switch. */
export function deviceConfig(env: Env, login: string | null): DeviceConfig {
  const model = isSet(env.ANTHROPIC_API_KEY);
  const orgs = (env.GITHUB_ORGS ?? "").split(",").map((org) => org.trim()).filter(Boolean);
  return {
    features: {
      ask_ai: askConfigured(env),
      key_lines: model,
      rewrite: model,
      feedback: feedbackConfigured(env),
      push: pushMode(env) !== "none",
      webhooks: isSet(env.WEBHOOK_SECRET),
    },
    login,
    ...(orgs.length > 0 ? { orgs } : {}),
  };
}
