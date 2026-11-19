// The AI container (docs/api.md, "AI on a subscription"): Claude Agent SDK runs, signed in with the Worker's
// CLAUDE_CODE_OAUTH_TOKEN. The Worker is its only caller; nothing here reaches R2 or keeps state between runs.
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { promisify } from "node:util";
import { InMemorySessionStore, query } from "@anthropic-ai/claude-agent-sdk";
import {
  askAnswer,
  createLocks,
  grantedRepos,
  parseBody,
  runAnswer,
  SeededStore,
  turnKeeper,
  vetQuestion,
} from "./ask-core.mjs";
import {
  lockConfig,
  readOnlyHooks,
  readToolNames,
  readTools,
  SERVER,
  WEB_TOOLS,
} from "./read-tools.mjs";
import { accountEnv } from "./replies.mjs";
import { authArgs, gitEnv, SAFE_GIT } from "./vet.mjs";

const exec = promisify(execFile);

const PORT = process.env.PORT === "0" ? 0 : Number(process.env.PORT) || 8080;

/** One structured answer: `{system, prompt, model, effort, schema}` in, the parsed output and what it spent out. */
async function run({ system, prompt, model, effort, schema, account }) {
  let result = null;
  for await (const message of query({
    prompt,
    options: {
      systemPrompt: system,
      model,
      effort,
      tools: [],
      settingSources: [],
      maxTurns: 3,
      sessionStore: new InMemorySessionStore(),
      env: accountEnv(account),
      outputFormat: { type: "json_schema", schema },
    },
  })) {
    if (message.type === "result") {
      result = message;
    }
  }
  if (!result) {
    throw new Error("The agent ended without a result.");
  }
  return runAnswer(result, model);
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
    const said =
      String(error?.stderr ?? "")
        .trim()
        .split("\n")
        .pop() || `exit ${error?.code ?? "?"}`;
    throw new Error(`git ${step} failed: ${said}`);
  }
}

/** One checkout at a time per directory: a second question on the same PR waits for the first's checkout. */
const locked = createLocks();

/** PR `number` of `repo` at `head`, in `dir`: one person's own (`scope`) for that PR. The token rides one command's header and is never written to disk. */
async function checkout(dir, repo, head, token) {
  const auth = authArgs(token);
  if (!existsSync(`${dir}/.git`)) {
    await git("init", ["init", "-q", dir]);
    await git("remote", ["-C", dir, "remote", "add", "origin", `https://github.com/${repo}.git`]);
  }
  await git("fetch", ["-C", dir, ...auth, "fetch", "-q", "--depth=50", "origin", head], {
    timeout: 300_000,
  });
  await git("checkout", ["-C", dir, "checkout", "-q", "--force", "--detach", head]);
  lockConfig(dir);
  return dir;
}

/** The PR's diff beside the code, as a file the read tools reach: git's own objects are compressed past reading. */
export const DIFF_FILE = ".prhub-pr.diff";

function placeDiff(dir, diff) {
  // A PR can commit this name as a symlink: whatever is there goes first, and the write makes a new file only.
  rmSync(`${dir}/${DIFF_FILE}`, { force: true, recursive: true });
  writeFileSync(`${dir}/${DIFF_FILE}`, diff ?? "", { flag: "wx" });
  writeFileSync(`${dir}/.git/info/exclude`, `${DIFF_FILE}\n`);
}

/** One Ask turn on `repo` at `head`: the answer's text, the session, and its whole transcript for the next turn. */
async function ask({
  system,
  prompt,
  model,
  effort,
  scope,
  repo,
  number,
  head,
  token,
  readOnly,
  reachable,
  diff,
  session,
  entries,
  budgetUsd,
  account,
}) {
  const unsafe = vetQuestion({ scope, repo, number, head });
  if (unsafe) {
    throw new Error(unsafe);
  }
  // Hosted, the repos this question's token names: the only clones the agent may read. Null on a Worker of one's own.
  const granted = grantedRepos(reachable);
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
    // The newest review the agent drafted (`draft_review`), what the reviewer asked it to do on GitHub (`github_act`),
    // and comments for the PR's Linear tickets (`linear_act`): all go to the Worker, never to GitHub or Linear from here.
    const { kept, onDraft, onAct, onLinear } = turnKeeper();
    let result = null;
    let tools = [];
    for await (const message of query({
      prompt,
      options: {
        systemPrompt: system,
        model,
        effort,
        cwd,
        tools: ASK_TOOLS,
        allowedTools: allowed,
        permissionMode: "dontAsk",
        mcpServers: {
          [SERVER]: readTools({
            prDir: cwd,
            prRepo: repo,
            clones,
            scope: home,
            token: reads,
            locked,
            reachable: granted,
            onDraft,
            onAct,
            onLinear,
          }),
        },
        settingSources: [],
        env: accountEnv(account),
        maxTurns: 60,
        maxBudgetUsd: budgetUsd ?? undefined,
        sessionStore: store,
        hooks: { PreToolUse: readOnlyHooks(cwd, clones, granted) },
        resume: session ?? undefined,
      },
    })) {
      if (message.type === "system" && message.subtype === "init") {
        tools = message.tools ?? [];
      }
      if (message.type === "result") {
        result = message;
      }
    }
    if (!result) {
      throw new Error("The agent ended without a result.");
    }
    return askAnswer({ result, tools, ...kept, entries: store.entries, model, token });
  });
}

const ROUTES = { "/run": run, "/ask": ask };

/**
 * The Worker stops an idle container with SIGTERM. Node is this container's first process, and a first process ignores
 * a signal it has no handler for, so the container never stopped: it ran on with the CLAUDE_CODE_OAUTH_TOKEN it started
 * with, whatever the Worker's secret had become since. Now it leaves, once no run is in flight.
 */
let inFlight = 0;
let leaving = false;
function leaveWhenIdle() {
  if (leaving && inFlight === 0) {
    process.exit(0);
  }
}
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    leaving = true;
    process.send?.({ type: "leaving", inFlight });
    leaveWhenIdle();
  });
}

const server = createServer(async (request, response) => {
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
  // In flight until its answer has left: a stop asked for meanwhile waits for it.
  inFlight++;
  response.once("close", () => {
    inFlight--;
    leaveWhenIdle();
  });
  let text = "";
  for await (const chunk of request) {
    text += chunk;
  }
  const { body, error } = parseBody(text);
  if (error) {
    response.statusCode = 400;
    response.end(JSON.stringify({ error }));
    return;
  }
  try {
    response.end(JSON.stringify(await route(body)));
  } catch (error) {
    response.statusCode = 500;
    response.end(JSON.stringify({ error: String(error instanceof Error ? error.message : error) }));
  }
});

server.listen(PORT, () => {
  // A supervising Node process can wait for the actual listening socket, including an assigned port.
  process.send?.({ type: "listening", port: server.address().port });
});
