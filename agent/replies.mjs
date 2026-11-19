// What Ask's tools say back, and the tools that only hand something to the Worker: no disk, no process, no SDK. The
// SDK wraps these handlers in read-tools.mjs.
import { cantAccess } from "./gate.mjs";
import { API, vetApiPath } from "./vet.mjs";

/** `text` with each secret given replaced by `[redacted]`; empty secrets are skipped. */
export function redact(text, secrets) {
  return secrets.reduce(
    (kept, secret) => (secret ? kept.split(secret).join("[redacted]") : kept),
    String(text),
  );
}

/**
 * The subscription's tokens: `CLAUDE_CODE_OAUTH_TOKEN` holds one, or several separated by commas or new lines, one per
 * Claude account. The Worker says which account a run uses (`account`), and moves to the next when one hits its limit.
 */
export function subscriptionTokens() {
  return (process.env.CLAUDE_CODE_OAUTH_TOKEN ?? "").split(/[\s,]+/).filter(Boolean);
}

/** Claude Code's environment for a run on account `account` (an index, wrapping round): its one token, alone. */
export function accountEnv(account) {
  const tokens = subscriptionTokens();
  const index = Number.isInteger(account) && tokens.length > 0 ? account % tokens.length : 0;
  return { ...process.env, CLAUDE_CODE_OAUTH_TOKEN: tokens[index] ?? "" };
}

/** The most characters one tool answer keeps, so one answer can't fill the context. */
export const KEPT = 60_000;

/** `text` cut at `KEPT` characters, saying where it was cut. */
export function cut(text) {
  return text.length > KEPT ? `${text.slice(0, KEPT)}\n[cut at ${KEPT} characters]` : text;
}

/** What a tool says back: cut, and with both tokens out of it. */
export function said(text, token) {
  return cut(redact(text, [token, ...subscriptionTokens()]));
}

/** One MCP tool answer. */
export const reply = (text, token, isError = false) => ({
  content: [{ type: "text", text: said(text, token) }],
  isError,
});

/** The most actions one turn takes on GitHub. */
export const ACTS = 10;

/** The most Linear comments one turn proposes. */
export const LINEAR_ACTS = 3;

/** draft_review: keeps the newest draft for the Worker, and posts nothing. */
export function draftReviewHandler(onDraft) {
  return async ({ event, body, comments }) => {
    onDraft({ event, body, comments });
    const lines = comments.length === 1 ? "1 line comment" : `${comments.length} line comments`;
    return reply(
      `Drafted: ${event} with ${lines}. Nothing is posted: the reviewer sees the draft under your answer and posts it. Say in one line what the draft does; don't repeat it.`,
      null,
    );
  };
}

/** github_act: queues one action for the Worker to take as the reviewer. */
export function actHandler(onAct) {
  return async ({ action }) => {
    onAct(action);
    return reply(
      "Queued: it goes to GitHub as the reviewer when your turn ends, and the chat shows the result. Don't say it is done yet.",
      null,
    );
  };
}

/** linear_act: proposes one comment on a ticket, for the reviewer to post from the phone. */
export function linearActHandler(onLinear) {
  return async ({ issue, body }) => {
    onLinear({ issue: issue.toUpperCase(), body });
    return reply(
      `Proposed: a comment on ${issue.toUpperCase()}. Nothing is posted: the reviewer sees it under your answer and posts it. Say in one line what it asks; don't say it is posted.`,
      null,
    );
  };
}

/** github_api: one GET on GitHub's REST API with `token`; a 404 or 403 on another repo says it can't be reached. */
export function githubApiHandler({ token, prRepo }) {
  return async ({ path }) => {
    const refused = vetApiPath(path);
    if (refused) {
      return reply(refused, token, true);
    }
    try {
      const response = await fetch(new URL(path, API), {
        method: "GET",
        redirect: "manual",
        signal: AbortSignal.timeout(60_000),
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${token}`,
          "User-Agent": "prhub-ask",
          "X-GitHub-Api-Version": "2022-11-28",
        },
      });
      const where = response.headers.get("location");
      const body = where ? `Redirected to ${where}` : await response.text();
      const named = /^\/repos\/([^/?]+\/[^/?]+)/.exec(path)?.[1];
      const denied =
        (response.status === 404 || response.status === 403) && named && named !== prRepo
          ? `\n${cantAccess(named)}`
          : "";
      return reply(`HTTP ${response.status}\n${body}${denied}`, token, !response.ok);
    } catch (error) {
      return reply(`GitHub could not be reached: ${error?.message ?? error}`, token, true);
    }
  };
}
