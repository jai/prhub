// The person's yes to a Linear comment an Ask answer proposed (docs/api.md, "Commenting on Linear").
import { askRecordKey } from "./ask-chat.ts";
import { isSubscriptionRecord, subscriptionChat } from "./ask-subscription.ts";
import type { Env } from "./env.ts";
import { prId, type RepoFullName } from "./ids.ts";
import { type LinearPosted, linearPostedKey, postToLinear, proposalRef, SESSION_ENDED, sessionNow } from "./linear-act.ts";
import type { WriteClaim } from "./write-receipts.ts";

/** Where each proposed Linear comment of the chat stands; nothing is read when no answer proposed one. */
export async function linearPosted(
  repo: RepoFullName, number: number, env: Env, messages: { linear?: unknown[] }[],
): Promise<Record<string, LinearPosted>> {
  if (!messages.some((message) => message.linear?.length)) {
    return {};
  }
  return await (await env.DIFFS.get(linearPostedKey(repo, number, env)))?.json<Record<string, LinearPosted>>() ?? {};
}

/** How often a card asks Linear where a running agent session stands. */
const SESSION_CHECK_MS = 30_000;

/**
 * The chat's posted comments with their agent sessions as Linear has them now: a session still running is asked about
 * again, at most every `SESSION_CHECK_MS`, and only while the chat is read.
 */
export async function linearPostedNow(
  repo: RepoFullName, number: number, env: Env, messages: { linear?: unknown[] }[], now = Date.now(),
): Promise<Record<string, LinearPosted>> {
  const posted = await linearPosted(repo, number, env, messages);
  const running = Object.entries(posted).filter(([, one]) => one.session && !SESSION_ENDED.has(one.session.status)
    && now - (one.checkedAt ?? one.at) >= SESSION_CHECK_MS);
  if (running.length === 0 || !env.LINEAR_API_KEY) {
    return posted;
  }
  await Promise.all(running.map(async ([ref, one]) => {
    posted[ref] = { ...one, session: await sessionNow(one.session!.id, env) ?? one.session, checkedAt: now };
  }));
  await env.DIFFS.put(linearPostedKey(repo, number, env), JSON.stringify(posted));
  return posted;
}

/**
 * `POST /prs/{owner}/{repo}/{n}/ask/linear` (docs/api.md, "Commenting on Linear"): the person's yes to one comment an
 * answer proposed. It posts as they wrote it on the card, with their own Linear key, once: a repeat finds it posted.
 */
export async function postAskLinear(
  repo: RepoFullName, number: number, input: { message: string; index: number }, env: Env,
  services: {
    claim: (key: string) => Promise<WriteClaim>; finish: (key: string, sent: boolean) => Promise<void>;
    /** Linear said the key may only read: Settings then says so. */
    readOnly: () => Promise<void>; now?: () => number;
  },
): Promise<{ status: number; body: unknown }> {
  const record = await (await env.DIFFS.get(askRecordKey(repo, number, env)))?.json<unknown>();
  const message = isSubscriptionRecord(record) ? record.messages.find((one) => one.id === input.message) : undefined;
  const proposal = message?.linear?.[input.index];
  if (!isSubscriptionRecord(record) || !message || !proposal) {
    return { status: 404, body: { error: "That comment is no longer in this chat." } };
  }
  if (proposal.problem) {
    return { status: 409, body: { error: proposal.problem } };
  }
  const now = services.now ?? Date.now;
  const ref = proposalRef(message.id, input.index);
  const key = `linear:${prId(repo, number)}:${ref}`;
  const posted = await linearPosted(repo, number, env, record.messages);
  const claim = posted[ref]?.state === "posted" ? "done" : await services.claim(key);
  if (claim === "busy") {
    return { status: 503, body: { error: "This is already being sent." } };
  }
  if (claim === "go") {
    const result = await postToLinear(proposal, env);
    await services.finish(key, "url" in result);
    if ("problem" in result && result.readOnly) {
      await services.readOnly().catch((error: unknown) => console.error("linear read-only mark failed", error));
    }
    const at = now();
    // Read again: another proposal of this chat may have posted meanwhile.
    const latest = await linearPosted(repo, number, env, record.messages);
    latest[ref] = "url" in result ? { state: "posted", url: result.url, problem: null, at, session: result.session }
      : { state: "failed", url: null, problem: result.problem, at };
    await env.DIFFS.put(linearPostedKey(repo, number, env), JSON.stringify(latest));
    console.log("ask_linear", { repo, number, user_id: env.SIGNED_IN_USER_ID ?? null, posted: "url" in result });
  }
  return { status: 200, body: subscriptionChat(record, now(), await linearPosted(repo, number, env, record.messages)) };
}
