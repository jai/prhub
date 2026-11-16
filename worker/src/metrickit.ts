// MetricKit reports (docs/api.md, "MetricKit reports"): the app hands each daily metric payload and each diagnostic
// payload iOS gives it to `POST /device/metrics`, and this keeps it in R2, one object per payload, under the day it
// covers. Only for whom the Worker's operator turned it on: `METRICKIT=on` on a self-hosted Worker, `METRICKIT_LOGINS`
// on the hosted one. Agents read the objects with the Cloudflare R2 API.
import { type Env, scopedKey } from "./env.ts";
import { sha256Hex } from "./pairing.ts";

/** A diagnostic payload with call stacks runs to a few hundred KB; anything past this is not MetricKit's. */
export const METRIC_PAYLOAD_MAX_BYTES = 2_000_000;
const KINDS = new Set(["metric", "diagnostic"]);
const DAY = /^\d{4}-\d{2}-\d{2}$/;

export function metricKitOn(env: Pick<Env, "METRICKIT">): boolean {
  return env.METRICKIT?.trim().toLowerCase() === "on";
}

/** The logins, lowercased, whose phones send MetricKit reports to the hosted Worker (`METRICKIT_LOGINS`). */
export function metricKitLogins(env: Pick<Env, "METRICKIT_LOGINS">): Set<string> {
  return new Set(
    (env.METRICKIT_LOGINS ?? "")
      .split(",")
      .map((login) => login.trim().toLowerCase())
      .filter(Boolean),
  );
}

export interface MetricReport {
  kind: "metric" | "diagnostic";
  /** The UTC day the payload covers, from its `timeStampEnd`. */
  day: string;
  build: string | null;
  os: string | null;
  device: string | null;
  payload: Record<string, unknown>;
}

function text(value: unknown, max: number): string | null {
  return typeof value === "string" && value !== "" && value.length <= max ? value : null;
}

/** What iOS writes as a timestamp: `2026-11-16 00:00:00 +0000`, or ISO 8601. Its UTC day. */
export function dayOf(stamp: unknown): string | null {
  if (typeof stamp !== "string") {
    return null;
  }
  const time = Date.parse(
    stamp.replace(/^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) ([+-]\d{2})(\d{2})$/, "$1T$2$3:$4"),
  );
  return Number.isNaN(time) ? null : new Date(time).toISOString().slice(0, 10);
}

/**
 * `{kind, build, os, device, payload}`, `payload` being MetricKit's `jsonRepresentation()` as a string. Null when it
 * is not one. The day comes from the payload's own end time, else its first diagnostic's, else now.
 */
export function parseMetricReport(body: unknown, now: Date): MetricReport | null {
  if (typeof body !== "object" || body === null) {
    return null;
  }
  const fields = body as Record<string, unknown>;
  if (
    typeof fields.kind !== "string" ||
    !KINDS.has(fields.kind) ||
    typeof fields.payload !== "string"
  ) {
    return null;
  }
  let payload: unknown;
  try {
    payload = JSON.parse(fields.payload);
  } catch {
    return null;
  }
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
    return null;
  }
  const stamps = payload as Record<string, unknown>;
  const day =
    dayOf(stamps.timeStampEnd) ?? dayOf(stamps.timeStampBegin) ?? now.toISOString().slice(0, 10);
  return {
    kind: fields.kind as MetricReport["kind"],
    day,
    build: text(fields.build, 64),
    os: text(fields.os, 64),
    device: text(fields.device, 64),
    payload: payload as Record<string, unknown>,
  };
}

/** Where a report is kept: by day, then kind and the payload's hash, so the same payload sent twice is one object. */
export async function metricKey(
  env: Pick<Env, "SIGNED_IN_USER_ID">,
  report: MetricReport,
  raw: string,
): Promise<string> {
  if (!DAY.test(report.day)) {
    throw new Error("bad day");
  }
  const hash = (await sha256Hex(raw)).slice(0, 16);
  return scopedKey(env, `metrickit/${report.day}/${report.kind}-${hash}.json`);
}

/** `POST /device/metrics`: `204` once kept; `404` when MetricKit reports are off for this person. */
export async function metricsRoute(
  request: Request,
  env: Env,
  now = new Date(),
): Promise<Response> {
  if (!metricKitOn(env)) {
    return Response.json(
      { error: "MetricKit reports are not set up on this Worker." },
      { status: 404 },
    );
  }
  const sent = await request.text();
  let body: unknown = null;
  try {
    body = sent.length <= METRIC_PAYLOAD_MAX_BYTES ? JSON.parse(sent) : null;
  } catch {
    body = null;
  }
  const report = parseMetricReport(body, now);
  if (!report) {
    return Response.json(
      {
        error: {
          code: "validation_error",
          message:
            "a report is {kind: metric or diagnostic, payload: MetricKit's JSON as a string}, at most 2 MB",
        },
      },
      { status: 400 },
    );
  }
  const raw = JSON.stringify(report.payload);
  await env.DIFFS.put(
    await metricKey(env, report, raw),
    JSON.stringify({
      kind: report.kind,
      day: report.day,
      received_at: now.toISOString(),
      build: report.build,
      os: report.os,
      device: report.device,
      payload: report.payload,
    }),
    {
      httpMetadata: { contentType: "application/json" },
      customMetadata: { kind: report.kind, build: report.build ?? "" },
    },
  );
  return new Response(null, { status: 204 });
}
