// The AI container (docs/api.md, "AI on a subscription"): Claude Agent SDK runs, signed in with the Worker's
// CLAUDE_CODE_OAUTH_TOKEN. The Worker is its only caller; nothing here reaches R2 or keeps state between runs.
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { promisify } from "node:util";
import { InMemorySessionStore, query } from "@anthropic-ai/claude-agent-sdk";
import {
  authArgs, gitEnv, lockConfig, readOnlyHooks, readToolNames, readTools, SAFE_GIT, SERVER, vetRepo, WEB_TOOLS,
} from "./read-tools.mjs";

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

/**
 * Read only, and no shell: Read, Grep and Glob, the read tools of `read-tools.mjs` (git, and with a read-only token
 * clone_repo and github_api), which this process runs, and the web, WebSearch and WebFetch, for docs, changelogs and
 * issues. Nothing a repo says can run a command beside this container's token, and no tool reads the tokens. What the
 * agent read can leave by a WebFetch URL: open by Jai's choice (`readOnlyHooks`).
 */
const ASK_TOOLS = ["Read", "Grep", "Glob", ...WEB_TOOLS];
const WORK = "/home/agent/work";

/** Git's own words on a failure, never the command line: that carries the token's header. */
async function git(step, args, options = {}) {
  try {
    return await exec("git", [...SAFE_GIT, ...args], { env: gitEnv(), ...options });
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
  const auth = authArgs(token);
  if (!existsSync(`${dir}/.git`)) {
    await git("init", ["init", "-q", dir]);
    await git("remote", ["-C", dir, "remote", "add", "origin", `https://github.com/${repo}.git`]);
  }
  await git("fetch", ["-C", dir, ...auth, "fetch", "-q", "--depth=50", "origin", head], { timeout: 300_000 });
  await git("checkout", ["-C", dir, "checkout", "-q", "--force", "--detach", head]);
  lockConfig(dir);
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

/** The PR's diff beside the code, as a file the read tools reach: git's own objects are compressed past reading. */
export const DIFF_FILE = ".prhub-pr.diff";

function placeDiff(dir, diff) {
  // A PR can commit this name as a symlink: whatever is there goes first, and the write makes a new file only.
  rmSync(`${dir}/${DIFF_FILE}`, { force: true, recursive: true });
  writeFileSync(`${dir}/${DIFF_FILE}`, diff ?? "", { flag: "wx" });
  writeFileSync(`${dir}/.git/info/exclude`, `${DIFF_FILE}\n`);
}

/** The subscription token and the GitHub token, never in an answer: a defence beside `readOnlyHooks`. */
function scrub(text, ...more) {
  return [process.env.CLAUDE_CODE_OAUTH_TOKEN, ...more].reduce(
    (kept, secret) => (secret && kept ? kept.split(secret).join("[redacted]") : kept), text);
}

/** One Ask turn on `repo` at `head`: the answer's text, the session, and its whole transcript for the next turn. */
const SAFE = { scope: /^[\w-]{1,64}$/, repo: /^[\w.-]+\/[\w.-]+$/, head: /^[0-9a-f]{40}$/ };

async function ask({
  system, prompt, model, effort, scope, repo, number, head, token, readOnly, reachable, diff, session, entries, budgetUsd,
}) {
  if (!SAFE.scope.test(scope) || !SAFE.repo.test(repo) || repo.includes("..") || !Number.isInteger(number)
    || !SAFE.head.test(head)) {
    throw new Error("The question names no PR this container can check out.");
  }
  // Hosted, the repos this question's token names: the only clones the agent may read. Null on a Worker of one's own.
  const granted = Array.isArray(reachable) ? reachable.filter((one) => vetRepo(one) === null) : null;
  const dir = `${WORK}/${scope}/${repo}/${number}`;
  // This person's other repos, cloned by clone_repo. GitHub owners never start with a dot, so no PR's checkout is here.
  const home = `${WORK}/${scope}`;
  const clones = `${home}/.clones`;
  mkdirSync(clones, { recursive: true });
  return locked(dir, async () => {
    const cwd = await checkout(dir, repo, head, token);
    placeDiff(cwd, diff);
    // Only a token the Worker vouches is read only reaches GitHub from the tools: anything else stays on the checkout.
    const reads = readOnly === true ? token : null;
    const allowed = [...ASK_TOOLS, ...readToolNames(reads !== null)];
    const store = new SeededStore(session ? entries : []);
    let result = null;
    for await (const message of query({
      prompt,
      options: {
        systemPrompt: system, model, effort, cwd, tools: ASK_TOOLS, allowedTools: allowed, permissionMode: "dontAsk",
        mcpServers: { [SERVER]: readTools({
          prDir: cwd, prRepo: repo, clones, scope: home, token: reads, locked, reachable: granted,
        }) },
        settingSources: [], maxTurns: 60, maxBudgetUsd: budgetUsd ?? undefined, sessionStore: store,
        hooks: { PreToolUse: readOnlyHooks(cwd, clones, granted) },
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
      text: typeof result.result === "string" ? scrub(result.result, token) : null,
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
