import assert from "node:assert/strict";
import { test } from "vitest";
import type { Env } from "../../src/env.ts";
import {
  type Count,
  durationOf,
  gitHubReserveOf,
  LimitName,
  limitsConfig,
  limitsOf,
  type Milliseconds,
  parseLimits,
  rateWindowOf,
  retentionOf,
  WorkerMode,
} from "../../src/limits.ts";
import { backoffOf } from "../../src/rate-limit.ts";
import { maxReposOf } from "../../src/repos.ts";
const MINUTE = 60_000;
const window = (count: number, windowMs: number) => ({
  count: count as Count,
  windowMs: windowMs as Milliseconds,
});

// --- Config ---------------------------------------------------------------------------------------------------------

test("unset, a self-hosted Worker keeps its behaviour from before limits: no per-person counts and no sweep", () => {
  const limits = parseLimits({}, WorkerMode.SelfHosted);
  for (const name of [
    LimitName.WritesPerMinute,
    LimitName.WritesPerHour,
    LimitName.AskQuestionsPerHour,
    LimitName.AskQuestionsPerDay,
    LimitName.AiJobsPerHour,
  ] as const) {
    assert.equal(rateWindowOf(limits, name), null, name);
  }
  assert.equal(retentionOf(limits), null);
  assert.equal(limits.optional.indexed_pull_requests_max, null);
  assert.deepEqual(gitHubReserveOf(limits), { share: 0.1, floor: 100 });
  assert.equal(limits.fixed.ask_session_budget_cents, 200);
  assert.equal(limits.fixed.indexed_repos_max, 3_000);
  assert.deepEqual(limits.problems, []);
});

test("unset, the hosted Worker counts each person and keeps 6c's sign-in numbers and intervals", () => {
  const limits = parseLimits({}, WorkerMode.Hosted);
  assert.deepEqual(rateWindowOf(limits, LimitName.SignInStartsPerIpPerMinute), window(10, MINUTE));
  assert.deepEqual(rateWindowOf(limits, LimitName.WritesPerHour), window(200, 60 * MINUTE));
  assert.deepEqual(
    rateWindowOf(limits, LimitName.AskQuestionsPerDay),
    window(150, 24 * 60 * MINUTE),
  );
  assert.equal(durationOf(limits, LimitName.PollIntervalMinutes), 10 * MINUTE);
  assert.equal(durationOf(limits, LimitName.InstallationSyncHours), 6 * 60 * MINUTE);
  assert.equal(durationOf(limits, LimitName.SignInCodeMinutes), 5 * MINUTE);
  assert.equal(retentionOf(limits), 30 * 24 * 60 * MINUTE);
});

test("a LIMIT_ var sets its limit; off turns off only a limit that may be off; anything else is a problem", () => {
  const limits = parseLimits(
    {
      LIMIT_WRITES_PER_MINUTE: " 3 ",
      LIMIT_ASK_QUESTIONS_PER_HOUR: "OFF",
      LIMIT_POLL_INTERVAL_MINUTES: "off",
      LIMIT_AI_JOBS_PER_HOUR: "ten",
      LIMIT_GITHUB_RESERVE_PERCENT: "95",
      LIMIT_SESSIONS_MAX: "0",
      LIMIT_WRITES_PER_HOUR: "",
      LIMIT_INDEXED_REPOS_MAX: "2.5",
    },
    WorkerMode.Hosted,
  );
  assert.deepEqual(rateWindowOf(limits, LimitName.WritesPerMinute), window(3, MINUTE));
  assert.equal(rateWindowOf(limits, LimitName.AskQuestionsPerHour), null);
  assert.deepEqual(
    rateWindowOf(limits, LimitName.WritesPerHour),
    window(200, 60 * MINUTE),
    "blank is unset",
  );
  assert.equal(durationOf(limits, LimitName.PollIntervalMinutes), 10 * MINUTE);
  assert.deepEqual(rateWindowOf(limits, LimitName.AiJobsPerHour), window(60, 60 * MINUTE));
  assert.equal(limits.fixed.github_reserve_percent, 10);
  assert.equal(limits.fixed.sessions_max, 20);
  assert.equal(limits.fixed.indexed_repos_max, 3_000);
  assert.deepEqual(limits.problems, [
    {
      variable: "LIMIT_AI_JOBS_PER_HOUR",
      value: "ten",
      reason: "must be a whole number from 1 to 100000 or off; using 60",
    },
    {
      variable: "LIMIT_GITHUB_RESERVE_PERCENT",
      value: "95",
      reason: "must be a whole number from 0 to 90; using 10",
    },
    { variable: "LIMIT_POLL_INTERVAL_MINUTES", value: "off", reason: "cannot be off; using 10" },
    {
      variable: "LIMIT_INDEXED_REPOS_MAX",
      value: "2.5",
      reason: "must be a whole number from 1 to 20000; using 3000",
    },
    {
      variable: "LIMIT_SESSIONS_MAX",
      value: "0",
      reason: "must be a whole number from 1 to 1000; using 20",
    },
  ]);
});

test("the Worker's mode picks the defaults, and the config shows each limit that applies in it", () => {
  assert.equal(limitsOf({ HOSTED: "on" }).mode, WorkerMode.Hosted);
  assert.equal(limitsOf({ HOSTED: "" }).mode, WorkerMode.SelfHosted);
  const shown = limitsConfig(limitsOf({ LIMIT_WRITES_PER_MINUTE: "5" }));
  assert.equal(shown.writes_per_minute, 5);
  assert.equal(shown.writes_per_hour, null);
  assert.equal("poll_interval_minutes" in shown, false, "a self-hosted Worker polls by its cron");
  assert.equal("sign_in_starts_per_ip_per_minute" in shown, false);
  assert.equal(
    limitsConfig(limitsOf({ HOSTED: "on" })).pairing_attempts_per_ip_per_hour,
    undefined,
  );
});

test("the GitHub reserve and the repo cap come from their vars", () => {
  const reserve = gitHubReserveOf(
    limitsOf({ LIMIT_GITHUB_RESERVE_PERCENT: "50", LIMIT_GITHUB_RESERVE_MINIMUM: "0" }),
  );
  const answer = (remaining: number) =>
    new Response(null, {
      headers: {
        "x-ratelimit-remaining": String(remaining),
        "x-ratelimit-limit": "5000",
        "x-ratelimit-reset": "1900000900",
      },
    });
  const now = 1_900_000_000_000;
  assert.equal(backoffOf(answer(2_600), now, reserve), null);
  assert.equal(backoffOf(answer(2_400), now, reserve)?.kind, "low");
  assert.equal(maxReposOf({ LIMIT_INDEXED_REPOS_MAX: "5" } as Env), 5);
});
