// The server's decisions, apart from its HTTP, git and SDK: what a request may name, what an answer says, and how runs
// on one directory take turns. No disk, no process, no SDK.
import { ACTS, LINEAR_ACTS, redact, subscriptionTokens } from "./replies.mjs";
import { vetRepo } from "./vet.mjs";

/** A request's body: a JSON object, or why it is refused. */
export function parseBody(text) {
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return { error: "The body is not JSON." };
  }
  return body !== null && typeof body === "object" && !Array.isArray(body)
    ? { body }
    : { error: "The body is not a JSON object." };
}

const SAFE = { scope: /^[\w-]{1,64}$/, repo: /^[\w.-]+\/[\w.-]+$/, head: /^[0-9a-f]{40}$/ };

/** Why a question names no PR this container can check out, or null. */
export function vetQuestion({ scope, repo, number, head }) {
  return typeof scope === "string" &&
    SAFE.scope.test(scope) &&
    typeof repo === "string" &&
    SAFE.repo.test(repo) &&
    !repo.includes("..") &&
    Number.isInteger(number) &&
    typeof head === "string" &&
    SAFE.head.test(head)
    ? null
    : "The question names no PR this container can check out.";
}

/** Hosted, the repos this question's token names that are repo names; null on a Worker of one's own. */
export function grantedRepos(reachable) {
  return Array.isArray(reachable) ? reachable.filter((one) => vetRepo(one) === null) : null;
}

/** The model that answered: the asked one when it ran, as Claude Code also calls a small model for its own chores. */
export function answeringModel(model, modelUsage) {
  const used = modelUsage ?? {};
  return model in used ? model : (Object.keys(used)[0] ?? model);
}

/** One `/run` result: its subtype, the parsed output, the model, the tokens spent, and the cost. */
export function runAnswer(result, model) {
  const usage = result.usage ?? {};
  return {
    subtype: result.subtype,
    output: result.structured_output ?? null,
    model: answeringModel(model, result.modelUsage),
    tokens: {
      input:
        (usage.input_tokens ?? 0) +
        (usage.cache_creation_input_tokens ?? 0) +
        (usage.cache_read_input_tokens ?? 0),
      output: usage.output_tokens ?? 0,
    },
    costUsd: result.total_cost_usd ?? null,
  };
}

/** `text` with the subscription token and `token` out of it: a defence beside `readOnlyHooks`. */
export function scrub(text, token) {
  return redact(text, [...subscriptionTokens(), token]);
}

/** One `/ask` answer, every text the agent wrote scrubbed of both tokens. */
export function askAnswer({ result, tools, draft, actions, linear, entries, model, token }) {
  return {
    subtype: result.subtype,
    // The tools the turn began with, for the Worker's log: what the agent could use, not what it says it could.
    tools,
    text: typeof result.result === "string" ? scrub(result.result, token) : null,
    draft: draft && {
      ...draft,
      body: scrub(draft.body, token),
      comments: draft.comments.map((one) => ({ ...one, body: scrub(one.body, token) })),
    },
    actions,
    linear: linear.map((one) => ({ ...one, body: scrub(one.body, token) })),
    session: result.session_id,
    entries,
    model: answeringModel(model, result.modelUsage),
    costUsd: result.total_cost_usd ?? null,
  };
}

/** What the agent is doing, in a few words for the chat, from one SDK message; null when it says nothing new. */
export function activityOf(message) {
  if (message.type !== "assistant") return null;
  const use = (message.message?.content ?? []).findLast((block) => block.type === "tool_use");
  if (!use) return null;
  if (use.name === "Read" && typeof use.input?.file_path === "string") {
    const name = use.input.file_path.split("/").pop();
    return name === DIFF_FILE ? "Reading the diff" : `Reading ${name}`;
  }
  if (use.name === "Grep" || use.name === "Glob") return "Searching the code";
  if (use.name === "WebSearch" || use.name === "WebFetch") return "Reading the web";
  if (/__linear_(issue|search)$/.test(use.name)) return "Reading Linear";
  return "Reading the repo";
}

/** The PR's diff beside the code, as a file the read tools reach: git's own objects are compressed past reading. */
export const DIFF_FILE = ".prhub-pr.diff";

/** What one turn hands the Worker: the newest draft, and actions and Linear comments up to their caps. */
export function turnKeeper() {
  const kept = { draft: null, actions: [], linear: [] };
  return {
    kept,
    onDraft: (made) => {
      kept.draft = made;
    },
    onAct: (action) => {
      if (kept.actions.length < ACTS) kept.actions.push(action);
    },
    onLinear: (comment) => {
      if (kept.linear.length < LINEAR_ACTS) kept.linear.push(comment);
    },
  };
}

/** How long a tool waits for the Worker's answer before it says there is none. */
export const NEED_WAIT_MS = 45_000;

/**
 * What a turn's tools ask of the Worker while the turn runs: `ask(write, linear)` writes one line of the answer,
 * `{"need": {"id", "linear"}}`, and waits for `settle(id, result)`, which the Worker's `POST /reply` calls. An id is
 * settled once; one nobody answers in `waitMs` says so, and the turn goes on.
 */
export function createNeeds(waitMs = NEED_WAIT_MS, newId = () => crypto.randomUUID()) {
  const waiting = new Map();
  return {
    ask(write, linear) {
      const id = newId();
      return new Promise((done) => {
        const timer = setTimeout(() => {
          waiting.delete(id);
          done({ text: "Linear did not answer in time. Say so; don't guess.", isError: true });
        }, waitMs);
        waiting.set(id, (result) => {
          clearTimeout(timer);
          waiting.delete(id);
          done(result);
        });
        write(`${JSON.stringify({ need: { id, linear } })}\n`);
      });
    },
    settle(id, result) {
      const done = waiting.get(id);
      if (!done) return false;
      done({ text: String(result?.text ?? ""), isError: result?.isError === true });
      return true;
    },
  };
}

/** One run at a time per key: a second waits for the first, whether the first succeeds or fails. */
export function createLocks() {
  const locks = new Map();
  return function locked(key, work) {
    const before = locks.get(key) ?? Promise.resolve();
    const turn = before.then(work, work);
    locks.set(
      key,
      turn.catch(() => {}),
    );
    return turn;
  };
}

/** The session's transcript, given whole by the Worker and handed back whole, so R2 keeps it between containers. */
export class SeededStore {
  constructor(entries) {
    this.entries = entries ?? [];
  }
  async append(key, entries) {
    if (key.subpath === undefined) {
      this.entries.push(...entries);
    }
  }
  async load(key) {
    return key.subpath === undefined && this.entries.length > 0 ? this.entries : null;
  }
}
