// Visible pushes a tap opens a PR from (docs/api.md, "Alerts"). The silent `pr_sync` wake is separate.
import type { PushMessage } from "./apns.ts";
import { type Env, isSet } from "./env.ts";
import type { RowStatus } from "./github.ts";
import { prId, type RepoFullName } from "./ids.ts";
import type { OpenList } from "./vocab.ts";

export type AlertKind = "review_requested" | "approved" | "changes_requested";

const KINDS: readonly AlertKind[] = ["review_requested", "approved", "changes_requested"];
/** A request older than this when the index first sees it is history, not news: a new Worker's first sync, say. */
export const ALERT_FRESH_MS = 2 * 60 * 60_000;
/** Long enough for a phone that was off overnight; an alert a day late is no use. */
const ALERT_LIFETIME_SECONDS = 24 * 60 * 60;
const MAX_TITLE = 120;
const MAX_BODY = 240;

export interface PrAlert {
  kind: AlertKind;
  repo: RepoFullName;
  number: number;
  head: string;
  title: string;
}

/** What the index held for a PR before this read: its list and review state, or null when it held none. */
export type HeldStatus = Pick<RowStatus, "list" | "review"> | null;

/** What this read says, with when review was last asked of the user (`reviewRequestedAt`). */
export interface ReadPullRequest {
  repo: RepoFullName;
  number: number;
  head: string;
  title: string;
  list: OpenList | null;
  review: string;
  requestedAt: string | null;
}

/**
 * The kinds `PR_ALERTS` turns on: comma-separated `review_requested`, `approved`, `changes_requested`. Unset or empty:
 * review requests alone. `off`: none. An unknown word is ignored.
 */
export function alertKinds(env: Pick<Env, "PR_ALERTS">): Set<AlertKind> {
  if (!isSet(env.PR_ALERTS)) {
    return new Set(["review_requested"]);
  }
  const words = env.PR_ALERTS.split(",").map((word) => word.trim().toLowerCase());
  return new Set(KINDS.filter((kind) => words.includes(kind)));
}

/**
 * The alerts a fresh read of a PR calls for, against what the index held. A review request alerts when the PR comes
 * onto the review list and the request is recent; a decision on the user's own PR alerts when it changes to approved
 * or changes requested on a PR already held. Dedupe on PR and head is the index's (`alertKey`).
 */
export function alertsFor(
  held: HeldStatus, pr: ReadPullRequest, kinds: ReadonlySet<AlertKind>, now: number,
): PrAlert[] {
  const alert = (kind: AlertKind): PrAlert => (
    { kind, repo: pr.repo, number: pr.number, head: pr.head, title: pr.title });
  const alerts: PrAlert[] = [];
  const isFresh = pr.requestedAt !== null && now - Date.parse(pr.requestedAt) <= ALERT_FRESH_MS;
  if (kinds.has("review_requested") && pr.list === "review" && held?.list !== "review" && isFresh) {
    alerts.push(alert("review_requested"));
  }
  if (pr.list === "mine" && held?.list === "mine" && held.review !== pr.review) {
    if (pr.review === "approved" && kinds.has("approved")) {
      alerts.push(alert("approved"));
    }
    if (pr.review === "changes_requested" && kinds.has("changes_requested")) {
      alerts.push(alert("changes_requested"));
    }
  }
  return alerts;
}

/** One alert of a kind per PR and head: asked again at the same commit, the user hears nothing new. */
export function alertKey(alert: Pick<PrAlert, "kind" | "repo" | "number" | "head">): string {
  return `${alert.kind}:${prId(alert.repo, alert.number)}@${alert.head}`;
}

const HEADINGS: Record<AlertKind, string> = {
  review_requested: "Review requested", approved: "Approved", changes_requested: "Changes requested",
};

function clip(text: string, limit: number): string {
  const characters = Array.from(text.trim());
  return characters.length <= limit ? characters.join("") : `${characters.slice(0, limit - 1).join("")}…`;
}

/** Room left in APNs' 4096 bytes for everything but `row`, whatever the title. */
const MAX_PAYLOAD_BYTES = 4000;

/**
 * The visible push: `pr` is what the app opens on a tap. `row` is the PR's row as `GET /prs` lists it now, so the
 * phone's Notification Service Extension (`mutable-content`) can fetch its stored detail and diff before the tap. A row
 * that would take the payload past APNs' limit is left out, and the phone then reads the PR on the tap.
 */
export function alertMessage(alert: PrAlert, row: object | null = null): PushMessage {
  const name = prId(alert.repo, alert.number);
  const payload: PushMessage["payload"] = {
    aps: {
      alert: { title: clip(`${HEADINGS[alert.kind]}: ${name}`, MAX_TITLE), body: clip(alert.title, MAX_BODY) },
      sound: "default",
      "thread-id": clip(`pr:${name}`, 64),
      "mutable-content": 1,
    },
    reason: "pr_alert",
    kind: alert.kind,
    pr: { repo: alert.repo, number: alert.number },
  };
  const withRow = row ? { ...payload, row } : payload;
  const fits = new TextEncoder().encode(JSON.stringify(withRow)).length <= MAX_PAYLOAD_BYTES;
  return {
    pushType: "alert", priority: 10, collapseId: null, lifetimeSeconds: ALERT_LIFETIME_SECONDS,
    payload: fits ? withRow : payload,
  };
}
