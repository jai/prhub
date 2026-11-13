/**
 * Which Claude model and effort each AI feature runs at (docs/api.md, "AI model choice"). Nothing here calls
 * anything. The Worker's vars narrow what this code supports; a request picks within that, or gets the feature's default.
 *
 * - `AI_MODELS_ALLOWED`: comma-separated model ids. Unset: every supported model.
 * - `AI_EFFORT_MAX`: `low`, `medium` or `high`. Unset: `high`. Nothing goes above `high`.
 * - `AI_DEFAULTS`: `key_lines=claude-sonnet-5-5:high,ask=claude-opus-5-5:medium`, or the same as JSON
 *   (`{"ask": "claude-opus-5-5:medium"}` or `{"ask": {"model": "claude-opus-5-5", "effort": "medium"}}`). A feature it
 *   leaves out keeps its built-in default.
 *
 * Bad config never stops a feature: each bad part is an `AiConfigProblem` (logged once in `/events`) and falls back to
 * the built-in value, clamped to what is allowed.
 */

import type { RepoFullName, Sha } from "./ids.ts";

export const SUPPORTED_MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"] as const;
export type ModelId = typeof SUPPORTED_MODELS[number];

/** In order: a later effort is "above" an earlier one. `xhigh` and `max` are never offered. */
export const EFFORTS = ["low", "medium", "high"] as const;
export type Effort = typeof EFFORTS[number];

export const AI_FEATURES = ["key_lines", "rewrite", "ask"] as const;
export type AiFeature = typeof AI_FEATURES[number];

export interface ModelChoice {
  readonly model: ModelId;
  readonly effort: Effort;
}

interface ModelSpec {
  readonly label: string;
  readonly efforts: readonly Effort[];
  /** What the API runs when no effort is sent. */
  readonly defaultEffort: Effort;
  /** `fallbacks: "default"` on a refusal. Haiku 5.5 has no server-side fallback. */
  readonly serverFallback: boolean;
  /** USD per million tokens. Haiku 5.5's rate rises above 100K input tokens. */
  readonly price: { input: number; output: number; longInput?: number; longOutput?: number; longFrom?: number };
}

export const MODEL_SPECS: Readonly<Record<ModelId, ModelSpec>> = {
  "claude-haiku-5-5": {
    label: "Haiku 5.5", efforts: EFFORTS, defaultEffort: "medium", serverFallback: false,
    price: { input: 0.1, output: 0.5, longInput: 0.5, longOutput: 2.5, longFrom: 100_000 },
  },
  "claude-sonnet-5-5": {
    label: "Sonnet 5.5", efforts: EFFORTS, defaultEffort: "high", serverFallback: true, price: { input: 2, output: 10 },
  },
  "claude-opus-5-5": {
    label: "Opus 5.5", efforts: EFFORTS, defaultEffort: "medium", serverFallback: true, price: { input: 4, output: 20 },
  },
};

/** What each feature ran at before the choice existed. Key lines and rewrites sent no effort: Sonnet 5.5's is `high`. */
export const BUILT_IN_DEFAULTS: Readonly<Record<AiFeature, ModelChoice>> = {
  key_lines: { model: "claude-sonnet-5-5", effort: "high" },
  rewrite: { model: "claude-sonnet-5-5", effort: "high" },
  ask: { model: "claude-opus-5-5", effort: "medium" },
};

export interface AiConfigProblem {
  variable: "AI_MODELS_ALLOWED" | "AI_EFFORT_MAX" | "AI_DEFAULTS";
  value: string;
  reason: string;
}

export interface AiConfig {
  /** Supported, in `SUPPORTED_MODELS` order, and allowed. Never empty. */
  readonly allowed: readonly ModelId[];
  readonly effortMax: Effort;
  readonly defaults: Readonly<Record<AiFeature, ModelChoice>>;
  readonly problems: readonly AiConfigProblem[];
}

export type AiConfigVars = Partial<Record<"AI_MODELS_ALLOWED" | "AI_EFFORT_MAX" | "AI_DEFAULTS", string>>;

export function isModelId(value: unknown): value is ModelId {
  return typeof value === "string" && (SUPPORTED_MODELS as readonly string[]).includes(value);
}

export function isEffort(value: unknown): value is Effort {
  return typeof value === "string" && (EFFORTS as readonly string[]).includes(value);
}

function isFeature(value: string): value is AiFeature {
  return (AI_FEATURES as readonly string[]).includes(value);
}

function rank(effort: Effort): number {
  return EFFORTS.indexOf(effort);
}

/** The efforts this config offers on a model: the model's own, up to the max. */
export function effortsFor(config: Pick<AiConfig, "effortMax">, model: ModelId): Effort[] {
  return MODEL_SPECS[model].efforts.filter((effort) => rank(effort) <= rank(config.effortMax));
}

function clampEffort(config: Pick<AiConfig, "effortMax">, model: ModelId, effort: Effort): Effort {
  const offered = effortsFor(config, model);
  return offered.includes(effort) ? effort : offered[offered.length - 1];
}

const blank = (value: string | undefined): boolean => value === undefined || value.trim() === "";

function parseAllowed(raw: string | undefined, problems: AiConfigProblem[]): ModelId[] {
  if (blank(raw)) {
    return [...SUPPORTED_MODELS];
  }
  const named = raw!.split(",").map((name) => name.trim()).filter(Boolean);
  for (const name of named.filter((one) => !isModelId(one))) {
    problems.push({ variable: "AI_MODELS_ALLOWED", value: name, reason: "not a model this code supports" });
  }
  const allowed = SUPPORTED_MODELS.filter((model) => named.includes(model));
  if (allowed.length === 0) {
    problems.push({ variable: "AI_MODELS_ALLOWED", value: raw!, reason: "allows no supported model; using all of them" });
    return [...SUPPORTED_MODELS];
  }
  return allowed;
}

function parseEffortMax(raw: string | undefined, problems: AiConfigProblem[]): Effort {
  const value = (raw ?? "").trim();
  if (value === "") {
    return "high";
  }
  if (!isEffort(value)) {
    problems.push({ variable: "AI_EFFORT_MAX", value, reason: "must be low, medium or high; using high" });
    return "high";
  }
  return value;
}

/** `model[:effort]`, or `{model, effort?}`. */
function parseChoiceText(value: unknown): { model: string; effort?: string } | null {
  if (typeof value === "string") {
    const [model, effort, extra] = value.trim().split(":");
    return model && extra === undefined ? { model, ...(effort === undefined ? {} : { effort }) } : null;
  }
  if (value && typeof value === "object" && typeof (value as { model?: unknown }).model === "string") {
    const { model, effort } = value as { model: string; effort?: unknown };
    return effort === undefined || typeof effort === "string" ? { model, ...(effort === undefined ? {} : { effort }) } : null;
  }
  return null;
}

function defaultEntries(raw: string): [string, unknown][] | null {
  const text = raw.trim();
  if (text.startsWith("{")) {
    try {
      const parsed: unknown = JSON.parse(text);
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? Object.entries(parsed) : null;
    } catch {
      return null;
    }
  }
  const entries: [string, unknown][] = [];
  for (const part of text.split(/[,;\s]+/).filter(Boolean)) {
    const split = part.indexOf("=");
    if (split < 1) {
      return null;
    }
    entries.push([part.slice(0, split), part.slice(split + 1)]);
  }
  return entries;
}

/** A default the config can't serve moves to the nearest one it can: the same model at a lower effort, else another. */
function fitDefault(
  config: Pick<AiConfig, "allowed" | "effortMax">, feature: AiFeature, wanted: ModelChoice, problems: AiConfigProblem[],
  value: string,
): ModelChoice {
  let { model, effort } = wanted;
  if (!config.allowed.includes(model)) {
    const builtIn = BUILT_IN_DEFAULTS[feature].model;
    const fallback = config.allowed.includes(builtIn) ? builtIn : config.allowed[0];
    if (value !== "") {
      problems.push({ variable: "AI_DEFAULTS", value, reason: `${feature}: ${model} is not allowed; using ${fallback}` });
    }
    model = fallback;
    effort = model === builtIn ? BUILT_IN_DEFAULTS[feature].effort : MODEL_SPECS[model].defaultEffort;
  }
  const clamped = clampEffort(config, model, effort);
  if (clamped !== effort && value !== "") {
    problems.push({ variable: "AI_DEFAULTS", value, reason: `${feature}: effort ${effort} is above the max; using ${clamped}` });
  }
  return { model, effort: clamped };
}

function parseDefaults(
  raw: string | undefined, config: Pick<AiConfig, "allowed" | "effortMax">, problems: AiConfigProblem[],
): Record<AiFeature, ModelChoice> {
  const wanted: Record<AiFeature, { choice: ModelChoice; value: string }> = {
    key_lines: { choice: BUILT_IN_DEFAULTS.key_lines, value: "" },
    rewrite: { choice: BUILT_IN_DEFAULTS.rewrite, value: "" },
    ask: { choice: BUILT_IN_DEFAULTS.ask, value: "" },
  };
  if (!blank(raw)) {
    const entries = defaultEntries(raw!);
    if (!entries) {
      problems.push({ variable: "AI_DEFAULTS", value: raw!, reason: "not feature=model:effort pairs or a JSON object" });
    }
    for (const [feature, value] of entries ?? []) {
      const shown = typeof value === "string" ? value : JSON.stringify(value);
      const text = parseChoiceText(value);
      if (!isFeature(feature)) {
        problems.push({ variable: "AI_DEFAULTS", value: feature, reason: "not a feature (key_lines, rewrite, ask)" });
      } else if (!text || !isModelId(text.model)) {
        problems.push({ variable: "AI_DEFAULTS", value: shown, reason: `${feature}: not a supported model` });
      } else if (text.effort !== undefined && !isEffort(text.effort)) {
        problems.push({ variable: "AI_DEFAULTS", value: shown, reason: `${feature}: effort must be low, medium or high` });
      } else {
        wanted[feature] = {
          choice: { model: text.model, effort: text.effort ?? MODEL_SPECS[text.model].defaultEffort }, value: shown,
        };
      }
    }
  }
  return {
    key_lines: fitDefault(config, "key_lines", wanted.key_lines.choice, problems, wanted.key_lines.value),
    rewrite: fitDefault(config, "rewrite", wanted.rewrite.choice, problems, wanted.rewrite.value),
    ask: fitDefault(config, "ask", wanted.ask.choice, problems, wanted.ask.value),
  };
}

export function parseAiConfig(vars: AiConfigVars): AiConfig {
  const problems: AiConfigProblem[] = [];
  const allowed = parseAllowed(vars.AI_MODELS_ALLOWED, problems);
  const effortMax = parseEffortMax(vars.AI_EFFORT_MAX, problems);
  const defaults = parseDefaults(vars.AI_DEFAULTS, { allowed, effortMax }, problems);
  return { allowed, effortMax, defaults, problems };
}

export type ChoiceResult = { ok: true; choice: ModelChoice } | { ok: false; error: string };

/**
 * A request's `model` and `effort`, each optional. No model: the feature's default. A model without an effort: the
 * default's effort when it is the default model, else that model's own default, kept under the max.
 */
export function resolveChoice(
  config: AiConfig, feature: AiFeature, requested: { model?: unknown; effort?: unknown },
): ChoiceResult {
  const fallback = config.defaults[feature];
  const model = requested.model ?? null;
  const effort = requested.effort ?? null;
  if (model !== null && (typeof model !== "string" || !isModelId(model) || !config.allowed.includes(model))) {
    return { ok: false, error: `model must be one of ${config.allowed.join(", ")}` };
  }
  const chosenModel: ModelId = model ?? fallback.model;
  const offered = effortsFor(config, chosenModel);
  if (effort !== null && (typeof effort !== "string" || !isEffort(effort) || !offered.includes(effort))) {
    return { ok: false, error: `effort must be one of ${offered.join(", ")} for ${chosenModel}` };
  }
  const chosenEffort: Effort = effort
    ?? (chosenModel === fallback.model ? fallback.effort : clampEffort(config, chosenModel, MODEL_SPECS[chosenModel].defaultEffort));
  return { ok: true, choice: { model: chosenModel, effort: chosenEffort } };
}

/** `GET /device/config`'s `ai.features.<feature>`. */
export interface FeatureModels {
  default: ModelChoice;
  allowed: { model: ModelId; label: string; efforts: Effort[] }[];
}

export function featureModels(config: AiConfig, feature: AiFeature): FeatureModels {
  return {
    default: config.defaults[feature],
    allowed: config.allowed.map((model) => ({ model, label: MODEL_SPECS[model].label, efforts: effortsFor(config, model) })),
  };
}

export function sameChoice(a: ModelChoice, b: ModelChoice): boolean {
  return a.model === b.model && a.effort === b.effort;
}

/**
 * List price of one Messages call, in cents, or null for a model this file has no price for (a refusal fallback can
 * answer on another model).
 */
export function costCents(model: string, tokens: { input: number; output: number }): number | null {
  if (!isModelId(model)) {
    return null;
  }
  const { price } = MODEL_SPECS[model];
  const isLong = price.longFrom !== undefined && tokens.input > price.longFrom;
  const input = isLong ? price.longInput! : price.input;
  const output = isLong ? price.longOutput! : price.output;
  const dollars = (tokens.input * input + tokens.output * output) / 1_000_000;
  return Math.round(dollars * 100 * 10_000) / 10_000;
}

export interface AiJob {
  kind: "key_lines" | "rewrite";
  repo: RepoFullName;
  number: number;
  head: Sha;
  /** Key lines only: lines of code either side of a change. 0 is the diff alone, -1 the whole file. */
  context: number;
  /** The model and effort. A job queued before the choice existed has none: it ran at the built-in default. */
  choice?: ModelChoice;
}

/**
 * Where a job's answer lands. The commit, the context, the model and the effort are in the name, so an answer is good for
 * ever. The built-in default keeps the name from before the choice existed, so answers made then are still found.
 */
export function aiKey({ kind, repo, number, head, context, choice }: AiJob): string {
  // v2: key lines with the PR's summary; answers kept before it are made again when next asked for.
  const name = kind === "key_lines" ? `key-lines-v2-${context}` : "rewrite";
  const model = choice && !sameChoice(choice, BUILT_IN_DEFAULTS[kind]) ? `-${choice.model}-${choice.effort}` : "";
  return `ai/${repo}/${number}/${head}/${name}${model}.json`;
}
