import type { Installation, IpLimit, SignIn, UserAccount } from "./account";
import type { AgentContainer } from "./agent-container-object";
import type { AiJobs } from "./ai-jobs";
import type { PrIndex } from "./pr-index";
import type { LimitVars } from "./limits";
import type { RateLimitState } from "./rate-limit";

/**
 * Jai's Worker sets everything here. A self-hosted one (docs/api.md) needs only `GITHUB_TOKEN` and its
 * bindings; every other name is optional, and the feature it serves is off without it (`GET /device/config`). The
 * `LIMIT_*` vars set the limits (`limits.ts`).
 */
export interface Env extends LimitVars {
  /** Whose PRs these are. Unset: read once from the token (`githubLogin`). */
  GITHUB_LOGIN?: string;
  /** A GitHub token that acts as that person: Jai's `gh` login, or a self-hoster's fine-grained PAT. */
  GITHUB_TOKEN: string;
  /**
   * Optional: the owners (orgs or users) the app filters to by default, comma-separated. The PR list never filters by it;
   * the repo index (`GET /repos`) lists only these owners' repos when it is set.
   */
  GITHUB_ORGS?: string;
  /**
   * Visible alerts (`alerts.ts`): `review_requested`, `approved`, `changes_requested`, comma-separated, or `off`.
   * Unset: review requests.
   */
  PR_ALERTS?: string;
  /** Jai's app's bearer, from his Pager Worker. Unset on a self-hosted Worker: paired devices only. */
  APP_TOKEN?: string;
  /** The threads hub's, for `POST /prs/states` and, as Feedback's runner, `/feedback/runner/*`. */
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
  /**
   * Jai's instance only: pushes go to his Agent Pager Worker (`POST /pr-push`), never to a device, so Agent Pager hears
   * from one Worker. Wins over the relay and direct APNs.
   */
  AGENT_PAGER_URL?: string;
  AGENT_PAGER_PUSH_TOKEN?: string;
  /** Push through Jai's relay (docs/push-relay.md), for the public PR app. Wins over direct APNs when both are set. */
  PUSH_RELAY_URL?: string;
  PUSH_RELAY_KEY?: string;
  /** Key lines and rewrites, when AI does not run on the subscription. */
  ANTHROPIC_API_KEY?: string;
  /**
   * A Claude subscription's token (`claude setup-token`): key lines and rewrites run on it in `AGENT`, the Agent SDK
   * container, and win over `ANTHROPIC_API_KEY`. On the hosted Worker, only for `SUBSCRIPTION_LOGINS`.
   */
  CLAUDE_CODE_OAUTH_TOKEN?: string;
  AGENT?: DurableObjectNamespace<AgentContainer>;
  /** `on`: key lines, rewrites and Ask may run on an API key. Anything else: on the subscription alone. */
  AI_ON_API_KEY?: string;
  /** Hosted only: the comma-separated GitHub logins whose AI runs on the Worker's subscription. Unset: nobody's. */
  SUBSCRIPTION_LOGINS?: string;
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
  /**
   * Feedback (`feedback.ts`), Jai's alone: the repo his app's feedback changes. Set, the Worker keeps feedback for the
   * runner on his Mac, which takes it with `HUB_TOKEN`.
   */
  FEEDBACK_REPO?: string;
  /**
   * Feedback as GitHub issues (`feedback-issues.ts`), the hosted Worker's: the public repo each person's feedback opens
   * an issue on, and the token that opens it. Both set, and no `FEEDBACK_REPO`, Feedback opens issues.
   */
  FEEDBACK_ISSUES_REPO?: string;
  FEEDBACK_ISSUES_TOKEN?: string;
  /** AI model choice (`models.ts`): allowed models, the effort cap, and each feature's default. Unset: all, high, built in. */
  AI_MODELS_ALLOWED?: string;
  AI_EFFORT_MAX?: string;
  AI_DEFAULTS?: string;
  /** Optional: a rewrite goes on without the ticket, and a PR's tickets without their Linear state, when it is not set. */
  LINEAR_API_KEY?: string;
  /** Accounts GitHub calls users that open PRs for someone else, comma-separated: their PRs say so (`requester.ts`). */
  BOT_AUTHORS?: string;
  /** The rewrite's writing guide: `owner/repo@ref` and the comma-separated paths in it. Unset: the built-in guide. */
  GUIDE_REPO?: string;
  GUIDE_FILES?: string;
  /** The review SLA's working week (`reviewWeek`). Unset: no due time on any row. */
  REVIEW_SLA_UTC_OFFSET_HOURS?: string;
  REVIEW_SLA_HOURS?: string;
  REVIEW_SLA_WEEKDAYS?: string;
  /** Where the PR index lives, as a Durable Object location hint (`apac` for Jai). Unset: wherever it is first used. */
  PR_INDEX_LOCATION?: string;
  /**
   * Hosted mode (`hosted.ts`, docs/api.md "Hosted sign-in"): `on` makes this the one Worker everyone signs in to with
   * the PRHub GitHub App, and `GITHUB_TOKEN` goes unused. It also needs the App's client ID and secret, the token key
   * and the three bindings below; without any of them the Worker answers 503 rather than act as a self-hosted one.
   */
  HOSTED?: string;
  GITHUB_APP_CLIENT_ID?: string;
  GITHUB_APP_CLIENT_SECRET?: string;
  /**
   * The App's id and PKCS#8 key, for installation tokens: Ask's read-only checkout of one repo, for a person who gave
   * their own Anthropic key. Sign-in and webhook routing need neither.
   */
  GITHUB_APP_ID?: string;
  GITHUB_APP_PRIVATE_KEY?: string;
  /** `<key id>:<base64 of 32 bytes>`, comma-separated, the sealing key first (`token-crypto.ts`). */
  TOKEN_ENCRYPTION_KEY?: string;
  /** `<team id>.<bundle id>` for `/.well-known/apple-app-site-association`, so the app can catch the callback. */
  APPLE_APP_ID?: string;
  USER_ACCOUNTS?: DurableObjectNamespace<UserAccount>;
  SIGN_INS?: DurableObjectNamespace<SignIn>;
  /** One per App installation, named `installation:<id>`: who can see which of its repos (`installation-core.ts`). */
  INSTALLATIONS?: DurableObjectNamespace<Installation>;
  /** One per client IP, named `ip:<SHA-256 of the IP>`: the per-IP sign-in limits (`limits.ts`). */
  IP_LIMITS?: DurableObjectNamespace<IpLimit>;
  /** Set by the Worker on the env it acts with for one signed-in person (`userEnv`); never a var. */
  SIGNED_IN_USER_ID?: string;
  /** Set by the PR index on the env a background run reads with (`rate-limit.ts`); never a var. */
  GITHUB_RATE?: RateLimitState;
  DIFFS: R2Bucket;
  PR_INDEX: DurableObjectNamespace<PrIndex>;
  AI_JOBS: DurableObjectNamespace<AiJobs>;
}

/** A name set to something. An empty var reads as unset, so a template's blanks turn a feature off. */
export function isSet(value: string | undefined): value is string {
  return typeof value === "string" && value.trim() !== "";
}

/**
 * A self-hosted Worker serves one person, so one index and one job queue. Jai's are named by his login, as they always
 * were; a self-hosted Worker's by a fixed name, so they don't wait on reading the login. On the hosted Worker each
 * signed-in person has their own, named by their GitHub user id, which never changes.
 */
function objectName(env: Env): string {
  if (isSet(env.SIGNED_IN_USER_ID)) {
    return `user:${env.SIGNED_IN_USER_ID}`;
  }
  return isSet(env.GITHUB_LOGIN) ? env.GITHUB_LOGIN : "self";
}

/** An R2 key as this env keeps it: under `users/<id>/` for a hosted person, so Delete Account can find it all. */
export function scopedKey(env: Pick<Env, "SIGNED_IN_USER_ID">, key: string): string {
  return isSet(env.SIGNED_IN_USER_ID) ? `users/${env.SIGNED_IN_USER_ID}/${key}` : key;
}

export function aiJobs(env: Env): DurableObjectStub<AiJobs> {
  return env.AI_JOBS.get(env.AI_JOBS.idFromName(objectName(env)));
}

/** Ask's questions: an `AiJobs` of their own, so none waits behind a key lines or rewrite job (`ask-queue.ts`). */
export function askQueue(env: Env): DurableObjectStub<AiJobs> {
  return env.AI_JOBS.get(env.AI_JOBS.idFromName(askQueueName(objectName(env))));
}

export function askQueueName(jobsName: string): string {
  return `${jobsName}/ask`;
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
