import type { AiJobs } from "./ai-jobs";
import type { PrIndex } from "./pr-index";

/**
 * Jai's Worker sets everything here. A self-hosted one (docs/api/pr-selfhost.md) needs only `GITHUB_TOKEN` and its
 * bindings; every other name is optional, and the feature it serves is off without it (`GET /device/config`).
 */
export interface Env {
  /** Whose PRs these are. Unset: read once from the token (`githubLogin`). */
  GITHUB_LOGIN?: string;
  /** A GitHub token that acts as that person: Jai's `gh` login, or a self-hoster's fine-grained PAT. */
  GITHUB_TOKEN: string;
  /** Optional: the owners (orgs or users) the app filters to by default, comma-separated. Reported, never enforced. */
  GITHUB_ORGS?: string;
  /** Jai's app's bearer, from his Pager Worker. Unset on a self-hosted Worker: paired devices only. */
  APP_TOKEN?: string;
  /** The threads hub's, for `POST /prs/states` alone. */
  HUB_TOKEN?: string;
  /** Optional webhooks (`/github/webhook`): without the secret the route is off and the one-minute poll does it all. */
  WEBHOOK_SECRET?: string;
  /** The webhook App's manifest flow (`setup.ts`): its one-time state, the org that owns it (unset: the user), its name. */
  SETUP_STATE?: string;
  GITHUB_APP_OWNER?: string;
  GITHUB_APP_NAME?: string;
  /** Direct APNs, for an app on this Worker's own Apple team (Jai's). */
  APNS_BUNDLE_ID?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_P8?: string;
  /** Push through Jai's relay (docs/api/push-relay.md), for the public PR app. Wins over direct APNs when both are set. */
  PUSH_RELAY_URL?: string;
  PUSH_RELAY_KEY?: string;
  /** Key lines and rewrites. */
  ANTHROPIC_API_KEY?: string;
  /** Ask (`ask.ts`): the key whose org holds the agent and environment. Unset: `ANTHROPIC_API_KEY`. */
  ASK_ANTHROPIC_API_KEY?: string;
  ASK_AGENT_ID?: string;
  ASK_ENVIRONMENT_ID?: string;
  /** The vault and its `GH_TOKEN` credential, which each question refreshes. */
  ASK_VAULT_ID?: string;
  ASK_CREDENTIAL_ID?: string;
  /** Jai's Ask GitHub App, which mints a read-only token per question. Unset: `ASK_GITHUB_TOKEN`, else `GITHUB_TOKEN`. */
  ASK_GITHUB_APP_ID?: string;
  /** PKCS#8 PEM. */
  ASK_GITHUB_APP_KEY?: string;
  /** A read-only PAT for the Ask agent, so it never holds the write token. */
  ASK_GITHUB_TOKEN?: string;
  /** Feedback (`feedback.ts`), Jai's alone, on Ask's key: the builder agent and the self-hosted environment on Borg Cube 04. */
  FEEDBACK_AGENT_ID?: string;
  FEEDBACK_ENVIRONMENT_ID?: string;
  /** Optional: a rewrite goes on without the ticket when it is not set. */
  LINEAR_API_KEY?: string;
  /** The rewrite's writing guide: `owner/repo@ref` and the comma-separated paths in it. Unset: the built-in guide. */
  GUIDE_REPO?: string;
  GUIDE_FILES?: string;
  /** The review SLA's working week (`reviewWeek`). Unset: no due time on any row. */
  REVIEW_SLA_UTC_OFFSET_HOURS?: string;
  REVIEW_SLA_HOURS?: string;
  REVIEW_SLA_WEEKDAYS?: string;
  /** Where the PR index lives, as a Durable Object location hint (`apac` for Jai). Unset: wherever it is first used. */
  PR_INDEX_LOCATION?: string;
  DIFFS: R2Bucket;
  PR_INDEX: DurableObjectNamespace<PrIndex>;
  AI_JOBS: DurableObjectNamespace<AiJobs>;
}

/** A name set to something. An empty var reads as unset, so a template's blanks turn a feature off. */
export function isSet(value: string | undefined): value is string {
  return typeof value === "string" && value.trim() !== "";
}

/**
 * Each Worker serves one person, so one index and one job queue. Jai's are named by his login, as they always were; a
 * self-hosted Worker's by a fixed name, so they don't wait on reading the login.
 */
function objectName(env: Env): string {
  return isSet(env.GITHUB_LOGIN) ? env.GITHUB_LOGIN : "self";
}

export function aiJobs(env: Env): DurableObjectStub<AiJobs> {
  return env.AI_JOBS.get(env.AI_JOBS.idFromName(objectName(env)));
}

export function prIndex(env: Env): DurableObjectStub<PrIndex> {
  const locationHint = isSet(env.PR_INDEX_LOCATION) ? env.PR_INDEX_LOCATION as DurableObjectLocationHint : undefined;
  return env.PR_INDEX.get(env.PR_INDEX.idFromName(objectName(env)), locationHint ? { locationHint } : undefined);
}

let knownLogin: { token: string; login: string } | null = null;

/** Whose PRs these are: `GITHUB_LOGIN`, else the token's own user, read once per isolate and per token. */
export async function githubLogin(env: Env): Promise<string> {
  if (isSet(env.GITHUB_LOGIN)) {
    return env.GITHUB_LOGIN;
  }
  if (knownLogin?.token === env.GITHUB_TOKEN) {
    return knownLogin.login;
  }
  const response = await fetch("https://api.github.com/user", {
    headers: {
      Accept: "application/vnd.github+json", Authorization: `Bearer ${env.GITHUB_TOKEN}`, "User-Agent": "pr-viewer",
    },
  });
  if (!response.ok) {
    throw new Error(`GitHub answered ${response.status} for the token's user`);
  }
  const { login } = await response.json<{ login: string }>();
  knownLogin = { token: env.GITHUB_TOKEN, login };
  return login;
}
