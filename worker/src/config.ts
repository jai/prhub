import { pushMode } from "./apns.ts";
import { makesAnswers, onApiKey, onSubscription } from "./agent-container.ts";
import { type Env, isSet } from "./env.ts";
import { type LimitName, limitsConfig, limitsOf } from "./limits.ts";
import { type AiConfig, type AiFeature, type FeatureModels, featureModels, parseAiConfig } from "./models.ts";

/** `GET /device/config` (docs/api.md): what this Worker can serve, so the app shows only that. */
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
  /** Model and effort per AI feature that is on. Absent when none is. */
  ai?: { features: Partial<Record<AiFeature, FeatureModels>> };
  /** Each limit in force in this Worker's mode, in its unit; null is off (docs/api.md, "Limits"). */
  limits: Partial<Record<LimitName, number | null>>;
}

let parsed: { key: string; config: AiConfig } | null = null;

/** The AI model config, parsed once per isolate and per value of its vars. */
export function aiConfigOf(env: Pick<Env, "AI_MODELS_ALLOWED" | "AI_EFFORT_MAX" | "AI_DEFAULTS">): AiConfig {
  const key = JSON.stringify([env.AI_MODELS_ALLOWED, env.AI_EFFORT_MAX, env.AI_DEFAULTS]);
  if (parsed?.key !== key) {
    parsed = { key, config: parseAiConfig(env) };
  }
  return parsed.config;
}

export function askConfigured(env: Env): boolean {
  return onSubscription(env) || onApiKey(env) && [env.ASK_AGENT_ID, env.ASK_ENVIRONMENT_ID, env.ASK_VAULT_ID, env.ASK_CREDENTIAL_ID].every(isSet)
    && (isSet(env.ASK_ANTHROPIC_API_KEY) || isSet(env.ANTHROPIC_API_KEY));
}

/** Jai's alone: the runner on his Mac takes feedback to a coding agent. A self-hosted Worker never sets these. */
export function feedbackConfigured(env: Env): boolean {
  return isSet(env.FEEDBACK_REPO) && isSet(env.HUB_TOKEN);
}

/** Feedback goes to the FeedbackKit Worker, which keeps every app's. */
export function featureKitConfigured(env: Env): boolean {
  return isSet(env.FEEDBACKKIT_URL) && isSet(env.FEEDBACKKIT_TOKEN) && isSet(env.FEEDBACKKIT_APP);
}

/** Feedback opens a GitHub issue (`feedback-issues.ts`): the hosted Worker's, for everyone signed in. */
export function feedbackIssuesConfigured(env: Env): boolean {
  return !feedbackConfigured(env) && isSet(env.FEEDBACK_ISSUES_REPO) && isSet(env.FEEDBACK_ISSUES_TOKEN);
}

/** Each feature is on when what serves it is configured; nothing is a separate switch. */
export function deviceConfig(env: Env, login: string | null): DeviceConfig {
  const model = makesAnswers(env);
  const orgs = (env.GITHUB_ORGS ?? "").split(",").map((org) => org.trim()).filter(Boolean);
  const ask = askConfigured(env);
  const on = ([["key_lines", model], ["rewrite", model], ["ask", ask]] as [AiFeature, boolean][])
    .filter(([, isOn]) => isOn).map(([feature]) => feature);
  const ai = aiConfigOf(env);
  return {
    features: {
      ask_ai: ask,
      key_lines: model,
      rewrite: model,
      feedback: featureKitConfigured(env) || feedbackConfigured(env) || feedbackIssuesConfigured(env),
      push: pushMode(env) !== "none",
      webhooks: isSet(env.WEBHOOK_SECRET),
    },
    login,
    ...(orgs.length > 0 ? { orgs } : {}),
    ...(on.length > 0 ? { ai: { features: Object.fromEntries(on.map((feature) => [feature, featureModels(ai, feature)])) } } : {}),
    limits: limitsConfig(limitsOf(env)),
  };
}
