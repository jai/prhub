/**
 * What crosses into the Worker, parsed once where it arrives: request bodies, and JSON read back from storage. Each
 * parser answers a typed value or null; a route answers a null with a 400, and a stored value that no longer parses is
 * treated as absent. Nothing past here takes a body's word for its shape.
 */
import { z } from "zod";
import { APNS_HOSTS, type ApnsHost } from "./apns.ts";
import type { AskInput } from "./ask-chat.ts";
import type { RowStatus } from "./github.ts";
import { type DeviceToken, parseRepoFullName, parseSha, type Sha } from "./ids.ts";
import { type AiJob, EFFORTS, SUPPORTED_MODELS } from "./models.ts";
import { MAX_KEY_LINE_ID } from "./reviewed-key-lines.ts";
import { PULL_REQUEST_CHECKS, PULL_REQUEST_MERGE_STATES, PULL_REQUEST_REVIEWS } from "./vocab.ts";
import type { Write } from "./write-input.ts";

function parser<Out>(schema: z.ZodType<Out>): (input: unknown) => Out | null {
  return (input) => {
    const parsed = schema.safeParse(input);
    return parsed.success ? parsed.data : null;
  };
}

const SHA = z.string().transform((value, context) => {
  const sha = parseSha(value);
  if (!sha) {
    context.addIssue({ code: "custom", message: "not a commit" });
    return z.NEVER;
  }
  return sha;
});

const REPO = z.string().transform((value, context) => {
  const repo = parseRepoFullName(value);
  if (!repo) {
    context.addIssue({ code: "custom", message: "not owner/name" });
    return z.NEVER;
  }
  return repo;
});

/** A request's JSON body; null when it is not JSON, which a route answers with a 400 rather than a 500. */
export async function bodyOf(request: Request): Promise<{ value: unknown } | null> {
  try {
    return { value: await request.json() };
  } catch {
    return null;
  }
}

// --- Devices --------------------------------------------------------------------------------------------------------

/** Apple's token for one install. The relay refuses anything else with `invalid_device_token` on every push. */
const DEVICE_TOKEN = /^[0-9a-fA-F]{2,200}$/;

export interface DeviceRegistration {
  token: DeviceToken;
  host: ApnsHost;
}

/** `POST /device/register`: `{token, host}`, the token lowercased as the relay keeps it. */
export const parseDeviceRegistration = parser<DeviceRegistration>(z.object({
  token: z.string().regex(DEVICE_TOKEN).transform((token) => token.toLowerCase() as DeviceToken),
  host: z.enum(APNS_HOSTS),
}));

/** A sync names the rows it fetched by id, so a phone with every row changed sends a few hundred. */
const MAX_CHANGED = 2_000;

export interface DeviceEvent {
  kind: string;
  detail: { changed?: string[]; complete?: boolean } & Record<string, unknown>;
}

/** `POST /device/event`: a kind, and whatever the phone says about it. `changed` and `complete` are read, so typed. */
export const parseDeviceEvent = parser<DeviceEvent>(z.looseObject({
  kind: z.string().min(1).max(64),
  changed: z.array(z.string().max(300)).max(MAX_CHANGED).optional(),
  complete: z.boolean().optional(),
}).transform(({ kind, ...detail }) => ({ kind, detail })));

// --- Writes and questions -------------------------------------------------------------------------------------------

const TEXT = z.string().min(1);
const SIDE = z.enum(["LEFT", "RIGHT"]);

const ReviewComment = z.object({ path: TEXT, line: z.number(), side: SIDE, body: TEXT });

const WriteSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("comment"), body: TEXT }),
  z.object({
    kind: z.literal("review"), event: z.enum(["APPROVE", "REQUEST_CHANGES", "COMMENT"]), body: z.string().default(""),
    commit: TEXT, comments: z.array(ReviewComment).default([]),
  }).refine((review) => review.event === "APPROVE" || review.body !== "" || review.comments.length > 0),
  z.object({ kind: z.literal("resolve"), thread: TEXT, resolved: z.boolean() }),
  z.object({ kind: z.literal("line"), body: TEXT, commit: TEXT, path: TEXT, line: z.number(), side: SIDE }),
  z.object({ kind: z.literal("reply"), body: TEXT, thread: TEXT }),
  z.object({ kind: z.literal("viewed"), pullRequest: TEXT, path: TEXT, viewed: z.boolean() }),
  z.object({ kind: z.literal("update_branch"), commit: TEXT }),
  z.object({ kind: z.literal("remove_request") }),
  z.object({
    kind: z.literal("checkbox"), index: z.number().int(), checked: z.boolean(),
    task: z.string().nullish().transform((task) => task ?? null),
  }),
  z.object({
    kind: z.literal("edit_body"), body: z.string(), base: z.string().nullish().transform((base) => base ?? null),
  }),
  z.object({ kind: z.literal("merge"), method: z.enum(["merge", "squash", "rebase"]), commit: TEXT }),
]);

/** `POST /prs/{owner}/{repo}/{n}/write`: one of the writes the viewer can post. */
export const parseWrite = parser<Write>(WriteSchema);

const MAX_QUESTION = 4_000;

const AskAnchor = z.object({ path: z.string(), line: z.number().int(), side: SIDE, code: z.string().optional() });

/** `POST /prs/{owner}/{repo}/{n}/ask`: the question, the head it is about, and a line when it is about one. */
export const parseAskInput = parser<AskInput>(z.object({
  question: z.string().max(MAX_QUESTION).transform((question) => question.trim()).pipe(TEXT),
  head: SHA,
  // A line that can't be read leaves the question about the whole PR, as it always has.
  anchor: z.unknown().optional().transform((anchor) => AskAnchor.safeParse(anchor).data ?? null),
}));

// --- Storage --------------------------------------------------------------------------------------------------------

const NULLABLE_TEXT = z.string().nullable();

const COMMON_STATUS = {
  author: NULLABLE_TEXT,
  checks: z.enum(PULL_REQUEST_CHECKS),
  review: z.enum(PULL_REQUEST_REVIEWS),
  merge: z.enum(PULL_REQUEST_MERGE_STATES),
  jaiReview: NULLABLE_TEXT,
  jaiReviewedAt: NULLABLE_TEXT,
};

/**
 * The status a row was stored with, in today's shape (`ROW_SHAPE`). A due time is kept on the review list alone; one a
 * row on another list was stored with, as all were before, is dropped.
 */
const RowStatusSchema = z.discriminatedUnion("list", [
  z.object({ list: z.literal("review"), ...COMMON_STATUS, reviewDueAt: NULLABLE_TEXT }),
  z.object({ list: z.literal("reviewed"), ...COMMON_STATUS }),
  z.object({ list: z.literal("mine"), ...COMMON_STATUS }),
  z.object({ list: z.literal("merged"), ...COMMON_STATUS, mergedAt: NULLABLE_TEXT }),
]);

/**
 * A row's stored status (`pull_requests.status`), or null when it is not in today's shape: one kept before a `ROW_SHAPE`
 * bump is served as no status, which the app already shows, until the alarm reads the PR again.
 */
export function parseRowStatus(stored: string | null): RowStatus | null {
  if (stored === null) {
    return null;
  }
  try {
    return parser<RowStatus>(RowStatusSchema)(JSON.parse(stored));
  } catch {
    return null;
  }
}

const AiJobSchema = z.object({
  kind: z.enum(["key_lines", "rewrite"]),
  repo: REPO,
  number: z.number().int().positive(),
  head: SHA,
  context: z.number().int(),
  choice: z.object({ model: z.enum(SUPPORTED_MODELS), effort: z.enum(EFFORTS) }).optional(),
});

/** A queued AI job read back from `AiJobs`; null when it is not one, and then it is dropped. */
export function parseAiJob(stored: string): AiJob | null {
  try {
    return parser<AiJob>(AiJobSchema)(JSON.parse(stored));
  } catch {
    return null;
  }
}

// --- Reviewed key lines (reviewed-key-lines.ts) ---------------------------------------------------------------------

export interface KeyLineMark {
  head: Sha;
  line: string;
  reviewed: boolean;
}

/** `POST /prs/{owner}/{repo}/{n}/key-lines-reviewed`: one key line, by its id, checked off at a head or back on. */
export const parseKeyLineMark = parser<KeyLineMark>(z.object({
  head: SHA,
  line: z.string().min(1).max(MAX_KEY_LINE_ID),
  reviewed: z.boolean(),
}));

// --- Hosted sign-in (hosted.ts, account.ts) -------------------------------------------------------------------------

/** What GitHub's token endpoint answers with a pair: `expires_in` and the refresh token are absent when tokens never expire. */
export interface TokenGrant {
  access_token: string;
  expires_in: number | null;
  refresh_token: string | null;
  refresh_token_expires_in: number | null;
}

/** GitHub's token endpoint, which answers `200` with `{error}` as often as with tokens. */
export const parseTokenGrant = parser<TokenGrant>(z.object({
  access_token: z.string().min(1).max(512),
  expires_in: z.number().int().positive().nullish().transform((value) => value ?? null),
  refresh_token: z.string().min(1).max(512).nullish().transform((value) => value ?? null),
  refresh_token_expires_in: z.number().int().positive().nullish().transform((value) => value ?? null),
}));

/** `{error}` from the token endpoint: `bad_refresh_token`, `bad_verification_code`, `incorrect_client_credentials`… */
export const parseOAuthError = parser<{ error: string }>(z.object({ error: z.string().min(1).max(100) }));

export interface GitHubUser {
  id: number;
  login: string;
}

/** `GET /user`: the id names the person for good; the login can change. */
export const parseGitHubUser = parser<GitHubUser>(z.object({
  id: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  login: z.string().regex(/^[A-Za-z0-9-]{1,39}$/),
}));

/** `POST /auth/github/finish`: the one-time code from the callback, and the PKCE verifier the app made. */
export const parseFinishInput = parser<{ code: string; code_verifier: string }>(z.object({
  code: z.string().min(1).max(200),
  code_verifier: z.string().regex(/^[A-Za-z0-9._~-]{43,128}$/),
}));

/** A webhook delivery that names a person: `github_app_authorization` names who revoked the App. */
export const parseSender = parser<{ action: string | null; sender: { id: number } }>(z.object({
  action: z.string().nullish().transform((value) => value ?? null),
  sender: z.object({ id: z.number().int().positive().max(Number.MAX_SAFE_INTEGER) }),
}));
