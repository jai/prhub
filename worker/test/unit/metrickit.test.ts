import assert from "node:assert/strict";
import { test } from "vitest";
import { deviceConfig } from "../../src/config.ts";
import type { Env } from "../../src/env.ts";
import { userEnv } from "../../src/hosted.ts";
import { dayOf, metricsRoute, parseMetricReport } from "../../src/metrickit.ts";

const now = new Date("2026-11-16T03:00:00Z");
const metricPayload = {
  timeStampBegin: "2026-11-15 00:00:00 +0000",
  timeStampEnd: "2026-11-15 23:59:00 +0000",
  cpuMetrics: { cumulativeCPUTime: "12 sec" },
};

function bucket() {
  const objects = new Map<string, { body: string; metadata: Record<string, string> | undefined }>();
  return {
    objects,
    put: async (
      key: string,
      body: string,
      options?: { customMetadata?: Record<string, string> },
    ) => {
      objects.set(key, { body, metadata: options?.customMetadata });
    },
  };
}

function post(body: unknown): Request {
  return new Request("https://worker.example/device/metrics", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("a MetricKit time stamp reads as its UTC day", () => {
  assert.equal(dayOf("2026-11-15 23:59:00 +0000"), "2026-11-15");
  assert.equal(
    dayOf("2026-11-16 01:00:00 +0700"),
    "2026-11-15",
    "a zone east of UTC is the day before",
  );
  assert.equal(dayOf("2026-11-15T10:00:00Z"), "2026-11-15");
  assert.equal(dayOf("yesterday"), null);
  assert.equal(dayOf(12), null);
});

test("a report is a kind and MetricKit's JSON; anything else is refused", () => {
  const report = parseMetricReport(
    {
      kind: "metric",
      payload: JSON.stringify(metricPayload),
      build: "301",
      os: "iPhone OS 27.2",
      device: "iPhone13,3",
    },
    now,
  );
  assert.deepEqual(
    report && { kind: report.kind, day: report.day, build: report.build, device: report.device },
    { kind: "metric", day: "2026-11-15", build: "301", device: "iPhone13,3" },
  );
  assert.equal(parseMetricReport({ kind: "crash", payload: "{}" }, now), null);
  assert.equal(parseMetricReport({ kind: "metric", payload: "not json" }, now), null);
  assert.equal(parseMetricReport({ kind: "metric", payload: "[1]" }, now), null);
  assert.equal(parseMetricReport({ kind: "metric", payload: { already: "an object" } }, now), null);
  assert.equal(
    parseMetricReport({ kind: "diagnostic", payload: "{}" }, now)?.day,
    "2026-11-16",
    "a payload with no time stamps is kept under the day it arrived",
  );
});

test("a report is kept once per payload, under the person's day, and only for whom it is on", async () => {
  const diffs = bucket();
  const off = await metricsRoute(
    post({ kind: "metric", payload: JSON.stringify(metricPayload) }),
    { DIFFS: diffs } as unknown as Env,
    now,
  );
  assert.equal(off.status, 404);
  assert.equal(diffs.objects.size, 0);

  const env = { DIFFS: diffs, METRICKIT: "on", SIGNED_IN_USER_ID: "42" } as unknown as Env;
  const body = { kind: "metric", payload: JSON.stringify(metricPayload), build: "301" };
  assert.equal((await metricsRoute(post(body), env, now)).status, 204);
  assert.equal((await metricsRoute(post(body), env, now)).status, 204);
  assert.equal(diffs.objects.size, 1, "the same payload twice is one object");
  const [[key, stored]] = [...diffs.objects];
  assert.match(key, /^users\/42\/metrickit\/2026-11-15\/metric-[0-9a-f]{16}\.json$/);
  const kept = JSON.parse(stored.body);
  assert.deepEqual(
    [kept.kind, kept.build, kept.received_at, kept.payload.cpuMetrics.cumulativeCPUTime],
    ["metric", "301", "2026-11-16T03:00:00.000Z", "12 sec"],
  );

  assert.equal((await metricsRoute(post("{"), env, now)).status, 400);
  assert.equal(
    (await metricsRoute(post({ kind: "metric", payload: "x".repeat(2_000_001) }), env, now)).status,
    400,
  );
});

test("the hosted Worker turns MetricKit reports on for METRICKIT_LOGINS only, and says so in its config", () => {
  const hosted = { HOSTED: "on", METRICKIT: "on", METRICKIT_LOGINS: " Octocat , ,alex" } as Env;
  const octocat = userEnv(hosted, { userId: "1", login: "octocat", token: "t" });
  const other = userEnv(hosted, { userId: "2", login: "someone", token: "t" });
  assert.equal(octocat.METRICKIT, "on");
  assert.equal(
    other.METRICKIT,
    undefined,
    "the Worker's own METRICKIT does not reach a person not listed",
  );
  assert.equal(deviceConfig(octocat, "octocat").metrickit, true);
  assert.equal("metrickit" in deviceConfig(other, "someone"), false);
  assert.equal(
    deviceConfig({ METRICKIT: "ON" } as Env, "alex").metrickit,
    true,
    "a self-hosted Worker's own switch",
  );
});
