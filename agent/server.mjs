// The AI container (docs/api.md, "AI on a subscription"): Claude Agent SDK runs, signed in with the Worker's
// CLAUDE_CODE_OAUTH_TOKEN. The Worker is its only caller; nothing here reaches R2 or keeps state between runs.
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
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

/** PR `number` of `repo` at `head`, in a directory of its own so two PRs never share a checkout. The token rides one command's header and is never written to disk. */
async function checkout(repo, number, head, token) {
  const dir = `${WORK}/${repo}/${number}`;
  const auth = ["-c", `http.extraHeader=Authorization: Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`];
  if (!existsSync(`${dir}/.git`)) {
    await exec("git", ["init", "-q", dir]);
    await exec("git", ["-C", dir, "remote", "add", "origin", `https://github.com/${repo}.git`]);
  }
  await exec("git", ["-C", dir, ...auth, "fetch", "-q", "--depth=50", "origin", head], { timeout: 300_000 });
  await exec("git", ["-C", dir, "checkout", "-q", "--force", "--detach", head]);
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

/** One Ask turn on `repo` at `head`: the answer's text, the session, and its whole transcript for the next turn. */
async function ask({ system, prompt, model, effort, repo, number, head, token, session, entries, budgetUsd }) {
  const cwd = await checkout(repo, number, head, token);
  const store = new SeededStore(session ? entries : []);
  let result = null;
  for await (const message of query({
    prompt,
    options: {
      systemPrompt: system, model, effort, cwd, tools: ASK_TOOLS, allowedTools: ASK_TOOLS, permissionMode: "dontAsk",
      settingSources: [], maxTurns: 40, maxBudgetUsd: budgetUsd ?? undefined, sessionStore: store,
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
    text: typeof result.result === "string" ? result.result : null,
    session: result.session_id,
    entries: store.entries,
    model: model in (result.modelUsage ?? {}) ? model : Object.keys(result.modelUsage ?? {})[0] ?? model,
    costUsd: result.total_cost_usd ?? null,
  };
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
