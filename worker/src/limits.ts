/**
 * Every limit the Worker enforces (docs/api.md, "Limits"), each set by its own `LIMIT_*` var. Nothing here counts or
 * enforces anything: `limit-counter.ts` counts, and the routes and objects read their numbers from `Limits` alone.
 *
 * A var is a whole number in the limit's unit, or `off` for a limit that may be turned off. Unset, a limit takes its
 * default for the Worker's mode. A self-hosted Worker's defaults keep its behaviour from before limits existed: no
 * per-person counts and no retention sweep. Bad config never stops a feature: each bad var is a `LimitsConfigProblem`
 * (logged once in `/events` as `limits_config_error`) and the default serves instead.
 */
import type { Brand } from "./ids.ts";

export const WorkerMode = { Hosted: "hosted", SelfHosted: "self_hosted" } as const;
export type WorkerMode = typeof WorkerMode[keyof typeof WorkerMode];

export const LimitName = {
  SignInStartsPerIpPerMinute: "sign_in_starts_per_ip_per_minute",
  SignInFinishesPerIpPerMinute: "sign_in_finishes_per_ip_per_minute",
  PairingAttemptsPerIpPerHour: "pairing_attempts_per_ip_per_hour",
  WritesPerMinute: "writes_per_minute",
  WritesPerHour: "writes_per_hour",
  AskQuestionsPerHour: "ask_questions_per_hour",
  AskQuestionsPerDay: "ask_questions_per_day",
  AiJobsPerHour: "ai_jobs_per_hour",
  AskSessionBudgetCents: "ask_session_budget_cents",
  GitHubReservePercent: "github_reserve_percent",
  GitHubReserveMinimum: "github_reserve_minimum",
  PollIntervalMinutes: "poll_interval_minutes",
  InstallationSyncHours: "installation_sync_hours",
  InstallationSyncOnOpenMinutes: "installation_sync_on_open_minutes",
  InstallationReadsNowPerMinute: "installation_reads_now_per_minute",
  IndexedPullRequestsMax: "indexed_pull_requests_max",
  IndexedReposMax: "indexed_repos_max",
  ClosedPullRequestRetentionDays: "closed_pull_request_retention_days",
  SessionLifetimeDays: "session_lifetime_days",
  SessionsMax: "sessions_max",
  SignInMinutes: "sign_in_minutes",
  SignInCodeMinutes: "sign_in_code_minutes",
} as const;
export type LimitName = typeof LimitName[keyof typeof LimitName];

const LimitUnit = {
  PerMinute: "per_minute",
  PerHour: "per_hour",
  PerDay: "per_day",
  Minutes: "minutes",
  Hours: "hours",
  Days: "days",
  Cents: "cents",
  Percent: "percent",
  Count: "count",
} as const;
type LimitUnit = typeof LimitUnit[keyof typeof LimitUnit];

export type Milliseconds = Brand<number, "Milliseconds">;
export type Count = Brand<number, "Count">;
export type Cents = Brand<number, "Cents">;

const MINUTE_MS = 60_000;
type RateUnit = typeof LimitUnit.PerMinute | typeof LimitUnit.PerHour | typeof LimitUnit.PerDay;
type DurationUnit = typeof LimitUnit.Minutes | typeof LimitUnit.Hours | typeof LimitUnit.Days;
const UNIT_MS: Readonly<Record<RateUnit | DurationUnit, number>> = {
  [LimitUnit.PerMinute]: MINUTE_MS,
  [LimitUnit.PerHour]: 60 * MINUTE_MS,
  [LimitUnit.PerDay]: 24 * 60 * MINUTE_MS,
  [LimitUnit.Minutes]: MINUTE_MS,
  [LimitUnit.Hours]: 60 * MINUTE_MS,
  [LimitUnit.Days]: 24 * 60 * MINUTE_MS,
};

/** `null` is off: no limit. */
type Setting = number | null;

interface LimitSpec {
  readonly variable: `LIMIT_${string}`;
  readonly unit: LimitUnit;
  /** The modes the limit applies in; `/device/config` shows only these. */
  readonly modes: readonly WorkerMode[];
  readonly defaults: Readonly<Record<WorkerMode, Setting>>;
  /** Whether `off` is a value it takes. */
  readonly canTurnOff: boolean;
  readonly min: number;
  readonly max: number;
}

const BOTH = [WorkerMode.Hosted, WorkerMode.SelfHosted] as const;
const HOSTED = [WorkerMode.Hosted] as const;
const SELF_HOSTED = [WorkerMode.SelfHosted] as const;
const RATE = { canTurnOff: true, min: 1, max: 100_000 } as const;

const LIMIT_SPECS = {
  [LimitName.SignInStartsPerIpPerMinute]: {
    variable: "LIMIT_SIGN_IN_STARTS_PER_IP_PER_MINUTE", unit: LimitUnit.PerMinute, modes: HOSTED,
    defaults: { hosted: 10, self_hosted: null }, ...RATE,
  },
  [LimitName.SignInFinishesPerIpPerMinute]: {
    variable: "LIMIT_SIGN_IN_FINISHES_PER_IP_PER_MINUTE", unit: LimitUnit.PerMinute, modes: HOSTED,
    defaults: { hosted: 10, self_hosted: null }, ...RATE,
  },
  [LimitName.PairingAttemptsPerIpPerHour]: {
    variable: "LIMIT_PAIRING_ATTEMPTS_PER_IP_PER_HOUR", unit: LimitUnit.PerHour, modes: SELF_HOSTED,
    defaults: { hosted: null, self_hosted: 30 }, ...RATE,
  },
  [LimitName.WritesPerMinute]: {
    variable: "LIMIT_WRITES_PER_MINUTE", unit: LimitUnit.PerMinute, modes: BOTH,
    defaults: { hosted: 20, self_hosted: null }, ...RATE,
  },
  [LimitName.WritesPerHour]: {
    variable: "LIMIT_WRITES_PER_HOUR", unit: LimitUnit.PerHour, modes: BOTH,
    defaults: { hosted: 200, self_hosted: null }, ...RATE,
  },
  [LimitName.AskQuestionsPerHour]: {
    variable: "LIMIT_ASK_QUESTIONS_PER_HOUR", unit: LimitUnit.PerHour, modes: BOTH,
    defaults: { hosted: 30, self_hosted: null }, ...RATE,
  },
  [LimitName.AskQuestionsPerDay]: {
    variable: "LIMIT_ASK_QUESTIONS_PER_DAY", unit: LimitUnit.PerDay, modes: BOTH,
    defaults: { hosted: 150, self_hosted: null }, ...RATE,
  },
  [LimitName.AiJobsPerHour]: {
    variable: "LIMIT_AI_JOBS_PER_HOUR", unit: LimitUnit.PerHour, modes: BOTH,
    defaults: { hosted: 60, self_hosted: null }, ...RATE,
  },
  [LimitName.AskSessionBudgetCents]: {
    variable: "LIMIT_ASK_SESSION_BUDGET_CENTS", unit: LimitUnit.Cents, modes: BOTH,
    defaults: { hosted: 200, self_hosted: 200 }, canTurnOff: false, min: 1, max: 100_000,
  },
  [LimitName.GitHubReservePercent]: {
    variable: "LIMIT_GITHUB_RESERVE_PERCENT", unit: LimitUnit.Percent, modes: BOTH,
    defaults: { hosted: 10, self_hosted: 10 }, canTurnOff: false, min: 0, max: 90,
  },
  [LimitName.GitHubReserveMinimum]: {
    variable: "LIMIT_GITHUB_RESERVE_MINIMUM", unit: LimitUnit.Count, modes: BOTH,
    defaults: { hosted: 100, self_hosted: 100 }, canTurnOff: false, min: 0, max: 5_000,
  },
  [LimitName.PollIntervalMinutes]: {
    variable: "LIMIT_POLL_INTERVAL_MINUTES", unit: LimitUnit.Minutes, modes: HOSTED,
    defaults: { hosted: 10, self_hosted: 10 }, canTurnOff: false, min: 1, max: 1_440,
  },
  [LimitName.InstallationSyncHours]: {
    variable: "LIMIT_INSTALLATION_SYNC_HOURS", unit: LimitUnit.Hours, modes: HOSTED,
    defaults: { hosted: 6, self_hosted: 6 }, canTurnOff: false, min: 1, max: 168,
  },
  [LimitName.InstallationSyncOnOpenMinutes]: {
    variable: "LIMIT_INSTALLATION_SYNC_ON_OPEN_MINUTES", unit: LimitUnit.Minutes, modes: HOSTED,
    defaults: { hosted: 10, self_hosted: 10 }, canTurnOff: false, min: 1, max: 1_440,
  },
  [LimitName.InstallationReadsNowPerMinute]: {
    variable: "LIMIT_INSTALLATION_READS_NOW_PER_MINUTE", unit: LimitUnit.PerMinute, modes: HOSTED,
    defaults: { hosted: 6, self_hosted: null }, ...RATE,
  },
  [LimitName.IndexedPullRequestsMax]: {
    variable: "LIMIT_INDEXED_PULL_REQUESTS_MAX", unit: LimitUnit.Count, modes: BOTH,
    defaults: { hosted: 500, self_hosted: null }, canTurnOff: true, min: 1, max: 100_000,
  },
  [LimitName.IndexedReposMax]: {
    variable: "LIMIT_INDEXED_REPOS_MAX", unit: LimitUnit.Count, modes: BOTH,
    defaults: { hosted: 3_000, self_hosted: 3_000 }, canTurnOff: false, min: 1, max: 20_000,
  },
  [LimitName.ClosedPullRequestRetentionDays]: {
    variable: "LIMIT_CLOSED_PULL_REQUEST_RETENTION_DAYS", unit: LimitUnit.Days, modes: BOTH,
    defaults: { hosted: 30, self_hosted: null }, canTurnOff: true, min: 1, max: 3_650,
  },
  [LimitName.SessionLifetimeDays]: {
    variable: "LIMIT_SESSION_LIFETIME_DAYS", unit: LimitUnit.Days, modes: HOSTED,
    defaults: { hosted: 180, self_hosted: 180 }, canTurnOff: false, min: 1, max: 3_650,
  },
  [LimitName.SessionsMax]: {
    variable: "LIMIT_SESSIONS_MAX", unit: LimitUnit.Count, modes: HOSTED,
    defaults: { hosted: 20, self_hosted: 20 }, canTurnOff: false, min: 1, max: 1_000,
  },
  [LimitName.SignInMinutes]: {
    variable: "LIMIT_SIGN_IN_MINUTES", unit: LimitUnit.Minutes, modes: HOSTED,
    defaults: { hosted: 10, self_hosted: 10 }, canTurnOff: false, min: 1, max: 60,
  },
  [LimitName.SignInCodeMinutes]: {
    variable: "LIMIT_SIGN_IN_CODE_MINUTES", unit: LimitUnit.Minutes, modes: HOSTED,
    defaults: { hosted: 5, self_hosted: 5 }, canTurnOff: false, min: 1, max: 60,
  },
} as const satisfies Readonly<Record<LimitName, LimitSpec>>;

type Specs = typeof LIMIT_SPECS;

/** Counted per person or per IP over a window (`limit-counter.ts`). */
export type RateLimitName = { [N in LimitName]: Specs[N]["unit"] extends RateUnit ? N : never }[LimitName];
/** Limits that `off` turns off. */
type OptionalLimitName = { [N in LimitName]: Specs[N]["canTurnOff"] extends true ? N : never }[LimitName];
/** Limits that always have a value. */
type FixedLimitName = Exclude<LimitName, OptionalLimitName>;
type FixedDurationName = { [N in FixedLimitName]: Specs[N]["unit"] extends DurationUnit ? N : never }[FixedLimitName];
type FixedCountName = Exclude<FixedLimitName, FixedDurationName>;

type LimitVariable = Specs[LimitName]["variable"];
export type LimitVars = Partial<Record<LimitVariable, string>>;

interface LimitsConfigProblem {
  variable: LimitVariable;
  value: string;
  reason: string;
}

export interface Limits {
  readonly mode: WorkerMode;
  readonly optional: Readonly<Record<OptionalLimitName, number | null>>;
  readonly fixed: Readonly<Record<FixedLimitName, number>>;
  readonly problems: readonly LimitsConfigProblem[];
}

export interface RateWindow {
  readonly count: Count;
  readonly windowMs: Milliseconds;
}

const LIMIT_NAMES = Object.values(LimitName);
const OFF = "off";

function isOptional(name: LimitName): name is OptionalLimitName {
  return LIMIT_SPECS[name].canTurnOff;
}

function parseSetting(name: LimitName, raw: string | undefined, mode: WorkerMode, problems: LimitsConfigProblem[]): Setting {
  const spec = LIMIT_SPECS[name];
  const fallback = spec.defaults[mode];
  const value = (raw ?? "").trim();
  if (value === "") {
    return fallback;
  }
  const shown = fallback === null ? OFF : String(fallback);
  if (value.toLowerCase() === OFF) {
    if (spec.canTurnOff) {
      return null;
    }
    problems.push({ variable: spec.variable, value, reason: `cannot be off; using ${shown}` });
    return fallback;
  }
  const number = /^\d+$/.test(value) ? Number(value) : Number.NaN;
  if (!Number.isSafeInteger(number) || number < spec.min || number > spec.max) {
    const range = `a whole number from ${spec.min} to ${spec.max}${spec.canTurnOff ? " or off" : ""}`;
    problems.push({ variable: spec.variable, value, reason: `must be ${range}; using ${shown}` });
    return fallback;
  }
  return number;
}

/** A record with every key filled by `valueOf`. */
function recordOf<Key extends string, Value>(keys: readonly Key[], valueOf: (key: Key) => Value): Record<Key, Value> {
  return Object.fromEntries(keys.map((key) => [key, valueOf(key)])) as Record<Key, Value>;
}

const OPTIONAL_NAMES = LIMIT_NAMES.filter(isOptional);
const FIXED_NAMES = LIMIT_NAMES.filter((name): name is FixedLimitName => !isOptional(name));

/** Every limit for a Worker in `mode`: each var parsed once, a bad one replaced by the default and named in `problems`. */
export function parseLimits(vars: LimitVars, mode: WorkerMode): Limits {
  const problems: LimitsConfigProblem[] = [];
  const settingFor = (name: LimitName) => parseSetting(name, vars[LIMIT_SPECS[name].variable], mode, problems);
  const optional = recordOf(OPTIONAL_NAMES, settingFor);
  const fixed = recordOf(FIXED_NAMES, (name) => settingFor(name) ?? LIMIT_SPECS[name].defaults[mode]);
  return { mode, optional, fixed, problems };
}

function workerModeOf(env: { HOSTED?: string }): WorkerMode {
  return env.HOSTED?.trim() === "on" ? WorkerMode.Hosted : WorkerMode.SelfHosted;
}

let parsed: { key: string; limits: Limits } | null = null;

/** The Worker's limits, parsed once per isolate and per value of their vars. */
export function limitsOf(env: LimitVars & { HOSTED?: string }): Limits {
  const mode = workerModeOf(env);
  const key = JSON.stringify([mode, ...LIMIT_NAMES.map((name) => env[LIMIT_SPECS[name].variable] ?? null)]);
  if (parsed?.key !== key) {
    parsed = { key, limits: parseLimits(env, mode) };
  }
  return parsed.limits;
}

function settingOf(limits: Limits, name: LimitName): number | null {
  return isOptional(name) ? limits.optional[name] : limits.fixed[name];
}

/** A counted limit's count and window; null when it is off. */
export function rateWindowOf(limits: Limits, name: RateLimitName): RateWindow | null {
  const count = limits.optional[name];
  return count === null ? null : { count: count as Count, windowMs: UNIT_MS[LIMIT_SPECS[name].unit] as Milliseconds };
}

export function durationOf(limits: Limits, name: FixedDurationName): Milliseconds {
  return limits.fixed[name] * UNIT_MS[LIMIT_SPECS[name].unit] as Milliseconds;
}

/**
 * The least time between two installation reads that `GET /device/config` waits for: a minute shared evenly by
 * `installation_reads_now_per_minute`. Off is no gap.
 */
export function readNowGapOf(limits: Limits): Milliseconds {
  const window = rateWindowOf(limits, LimitName.InstallationReadsNowPerMinute);
  return (window ? Math.ceil(window.windowMs / window.count) : 0) as Milliseconds;
}

export function countOf(limits: Limits, name: FixedCountName): Count {
  return limits.fixed[name] as Count;
}

/** How long a closed PR's stored diffs, details and AI answers are kept; null keeps them. */
export function retentionOf(limits: Limits): Milliseconds | null {
  const days = limits.optional[LimitName.ClosedPullRequestRetentionDays];
  return days === null ? null : days * UNIT_MS[LimitUnit.Days] as Milliseconds;
}

/** The most PRs one index holds; null holds every one. */
export function indexedPullRequestsMaxOf(limits: Limits): Count | null {
  return limits.optional[LimitName.IndexedPullRequestsMax] as Count | null;
}

export function askBudgetOf(limits: Limits): Cents {
  return limits.fixed[LimitName.AskSessionBudgetCents] as Cents;
}

/** What a token keeps back from background reads (`rate-limit.ts`): a share of its hour, and at least a floor. */
export interface GitHubReserve {
  readonly share: number;
  readonly floor: number;
}

export function gitHubReserveOf(limits: Limits): GitHubReserve {
  return {
    share: limits.fixed[LimitName.GitHubReservePercent] / 100,
    floor: limits.fixed[LimitName.GitHubReserveMinimum],
  };
}

/** `GET /device/config`'s `limits`: each limit that applies in this mode, by name, in its unit; null is off. */
export function limitsConfig(limits: Limits): Partial<Record<LimitName, number | null>> {
  return Object.fromEntries(LIMIT_NAMES
    .filter((name) => (LIMIT_SPECS[name].modes as readonly WorkerMode[]).includes(limits.mode))
    .map((name) => [name, settingOf(limits, name)]));
}

/** `429 limit_reached`: which limit, and when it lets the request through again. */
export function limitReachedAnswer(name: LimitName, retryAfterMs: number): Response {
  const retryAfter = Math.max(1, Math.ceil(retryAfterMs / 1_000));
  return Response.json({
    error: { code: "limit_reached", message: `${name} reached; try again in ${retryAfter} s`, limit: name,
      retry_after: retryAfter },
  }, { status: 429, headers: { "Retry-After": String(retryAfter), "Cache-Control": "no-store" } });
}
