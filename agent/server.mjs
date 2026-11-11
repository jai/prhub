// The AI container (docs/api.md, "AI on a subscription"): Claude Agent SDK runs, signed in with the Worker's
// CLAUDE_CODE_OAUTH_TOKEN. The Worker is its only caller; nothing here reaches R2 or keeps state between runs.
import { execFile } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { isAbsolute, relative, resolve } from "node:path";
import { createServer } from "node:http";
import { promisify } from "node:util";
import { InMemorySessionStore, query } from "@anthropic-ai/claude-agent-sdk";

const exec = promisify(execFile);

const PORT = 8080;

/** One structured answer: `{system, prompt, model, effort, schema}` in, the parsed output and what it spent out. */
async function run({ system, prompt, model, effort, schema }) {
  let result = null;
  for await (const message of query({
    prompt,
    options: {
      systemPrompt: system, model, effort, tools: [], settingSources: [], maxTurns: 3,
      sessionStore: new InMemorySessionStore(), outputFormat: { type: "json_schema", schema },
    },
  })) {
    if (message.type === "result") {
      result = message;
    }
  }
  if (!result) {
    throw new Error("The agent ended without a result.");
  }
  const usage = result.usage ?? {};
  return {
    subtype: result.subtype,
    output: result.structured_output ?? null,
    // Claude Code also calls a small model for its own chores; the answer is the asked model's when it ran.
    model: model in (result.modelUsage ?? {}) ? model : Object.keys(result.modelUsage ?? {})[0] ?? model,
    tokens: {
      input: (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0),
      output: usage.output_tokens ?? 0,
    },
    costUsd: result.total_cost_usd ?? null,
  };
}

/** Read only: no shell, so nothing a repo says can run a command beside this container's token. */
const ASK_TOOLS = ["Read", "Grep", "Glob"];
const WORK = "/home/agent/work";

/** Git's own words on a failure, never the command line: that carries the token's header. */
async function git(step, args, options = {}) {
  try {
    return await exec("git", args, options);
  } catch (error) {
    const said = String(error?.stderr ?? "").trim().split("\n").pop() || `exit ${error?.code ?? "?"}`;
    throw new Error(`git ${step} failed: ${said}`);
  }
}

/** One checkout at a time per directory: a second question on the same PR waits for the first's checkout. */
const locks = new Map();
async function locked(dir, work) {
  const before = locks.get(dir) ?? Promise.resolve();
  const turn = before.then(work, work);
  locks.set(dir, turn.catch(() => {}));
  return turn;
}

/** PR `number` of `repo` at `head`, in `dir`: one person's own (`scope`) for that PR. The token rides one command's header and is never written to disk. */
async function checkout(dir, repo, head, token) {
  const auth = ["-c", `http.extraHeader=Authorization: Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`];
  if (!existsSync(`${dir}/.git`)) {
    await git("init", ["init", "-q", dir]);
    await git("remote", ["-C", dir, "remote", "add", "origin", `https://github.com/${repo}.git`]);
  }
  await git("fetch", ["-C", dir, ...auth, "fetch", "-q", "--depth=50", "origin", head], { timeout: 300_000 });
  await git("checkout", ["-C", dir, "checkout", "-q", "--force", "--detach", head]);
  return dir;
}

/** The session's transcript, given whole by the Worker and handed back whole, so R2 keeps it between containers. */
class SeededStore {
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

/** Whether `path`, symlinks followed, is inside `root`. A path that does not exist yet is judged as written. */
function isInside(root, path) {
  const absolute = isAbsolute(path) ? path : resolve(root, path);
  let real = absolute;
  try {
    real = realpathSync(absolute);
  } catch {}
  const from = relative(realpathSync(root), real);
  return from === "" || (!from.startsWith("..") && !isAbsolute(from));
}

/** Every Read, Grep and Glob stays in the checkout: nothing outside it, such as /proc, holds anything to answer from. */
function insideOnly(cwd) {
  return [{
    matcher: "Read|Grep|Glob",
    hooks: [async (input) => {
      const { file_path: file, path } = input.tool_input ?? {};
      const target = file ?? path ?? cwd;
      return isInside(cwd, target) ? {} : {
        hookSpecificOutput: {
          hookEventName: "PreToolUse", permissionDecision: "deny",
          permissionDecisionReason: "Only the repository's own files can be read.",
        },
      };
    }],
  }];
}

/** The subscription token, never in an answer: a defence beside `insideOnly`. */
function scrub(text) {
  const token = process.env.CLAUDE_CODE_OAUTH_TOKEN;
  return token && text ? text.split(token).join("[redacted]") : text;
}

/** One Ask turn on `repo` at `head`: the answer's text, the session, and its whole transcript for the next turn. */
const SAFE = { scope: /^[\w-]{1,64}$/, repo: /^[\w.-]+\/[\w.-]+$/, head: /^[0-9a-f]{40}$/ };

async function ask({ system, prompt, model, effort, scope, repo, number, head, token, session, entries, budgetUsd }) {
  if (!SAFE.scope.test(scope) || !SAFE.repo.test(repo) || repo.includes("..") || !Number.isInteger(number)
    || !SAFE.head.test(head)) {
    throw new Error("The question names no PR this container can check out.");
  }
  const dir = `${WORK}/${scope}/${repo}/${number}`;
  return locked(dir, async () => {
    const cwd = await checkout(dir, repo, head, token);
    const store = new SeededStore(session ? entries : []);
    let result = null;
    for await (const message of query({
      prompt,
      options: {
        systemPrompt: system, model, effort, cwd, tools: ASK_TOOLS, allowedTools: ASK_TOOLS, permissionMode: "dontAsk",
        settingSources: [], maxTurns: 40, maxBudgetUsd: budgetUsd ?? undefined, sessionStore: store,
        hooks: { PreToolUse: insideOnly(cwd) },
        resume: session ?? undefined,
      },
    })) {
      if (message.type === "result") {
        result = message;
      }
    }
    if (!result) {
      throw new Error("The agent ended without a result.");
    }
    return {
      subtype: result.subtype,
      text: typeof result.result === "string" ? scrub(result.result) : null,
      session: result.session_id,
      entries: store.entries,
      model: model in (result.modelUsage ?? {}) ? model : Object.keys(result.modelUsage ?? {})[0] ?? model,
      costUsd: result.total_cost_usd ?? null,
    };
  });
}

const ROUTES = { "/run": run, "/ask": ask };

createServer(async (request, response) => {
  response.setHeader("content-type", "application/json");
  if (request.method === "GET" && request.url === "/health") {
    response.end('{"ok":true}');
    return;
  }
  const route = ROUTES[request.url ?? ""];
  if (request.method !== "POST" || !route) {
    response.statusCode = 404;
    response.end('{"error":"not found"}');
    return;
  }
  let body = "";
  for await (const chunk of request) {
    body += chunk;
  }
  try {
    response.end(JSON.stringify(await route(JSON.parse(body))));
  } catch (error) {
    response.statusCode = 500;
    response.end(JSON.stringify({ error: String(error instanceof Error ? error.message : error) }));
  }
}).listen(PORT);
