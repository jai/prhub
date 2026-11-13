// Ask's reads beyond the checkout (docs/api.md, "AI on a subscription"): git in a checkout or a cloned repo, cloning
// another repo, and GETs on GitHub's API. Each is a tool this process runs, never a shell: the agent names a git
// subcommand and its arguments, or an API path, and the token stays here. The vetting below gates each call twice, in
// the PreToolUse hook and again in the tool itself.
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { promisify } from "node:util";
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

const exec = promisify(execFile);

/** The MCP server's name: its tools are `mcp__prhub__<name>`. */
export const SERVER = "prhub";

/** Git subcommands that only read. `fetch`, `checkout` and every other writer are not here. */
export const GIT_READS = new Set([
  "log", "show", "diff", "grep", "blame", "shortlog", "describe", "rev-parse", "rev-list", "merge-base", "name-rev",
  "ls-files", "ls-tree", "cat-file", "for-each-ref",
]);

/** Options that write a file, read one from outside the repo, or run a program, whatever the subcommand. */
const GIT_DENIED = ["--output", "--no-index", "--ext-diff", "--open-files-in-pager", "--contents", "--file", "--exec"];

/** Why a git call is refused, or null when it only reads. `args` start with the subcommand. */
export function vetGit(args) {
  if (!Array.isArray(args) || args.length === 0 || args.some((arg) => typeof arg !== "string")) {
    return "Give git a subcommand and its arguments, as a list of strings.";
  }
  const [command, ...rest] = args;
  if (!GIT_READS.has(command)) {
    return `git ${command} is not allowed. Allowed: ${[...GIT_READS].join(", ")}.`;
  }
  for (const arg of rest) {
    if (arg.includes("\0") || arg.includes("\n")) {
      return "An argument holds a control character.";
    }
    const name = arg.split("=")[0];
    // Git takes a long option's unique prefix too: `--outp` is `--output`.
    if (name.startsWith("--") && name.length > 2 && GIT_DENIED.some((denied) => denied.startsWith(name))) {
      return `${name} is not allowed: it writes a file, reads one outside the repo, or runs a program.`;
    }
    // A path outside the repo turns `git diff` into a diff of any two files: every path stays inside.
    if (!arg.startsWith("-") && (isAbsolute(arg) || arg.startsWith("~") || arg.split(/[\\/]/).includes(".."))) {
      return "Paths stay inside the repo: no absolute paths, ~ or ...";
    }
    // grep's -O opens a pager program and -f reads patterns from any file, alone or among other short options.
    if (command === "grep" && /^-[^-]/.test(arg) && /[Of]/.test(arg)) {
      return "git grep's -O and -f are not allowed.";
    }
  }
  return null;
}

/** `owner/name` as GitHub spells them, and nothing that climbs a directory. */
const REPO = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9_.-]{1,100}$/;

export function vetRepo(repo) {
  return typeof repo === "string" && REPO.test(repo) && !repo.split("/").some((part) => part === "." || part === "..")
    ? null : "Name a repo as owner/name.";
}

/** A branch, tag or commit: no option, no climbing, no spaces. */
export function vetRef(ref) {
  return ref === undefined || (typeof ref === "string" && /^[A-Za-z0-9_][\w./-]{0,199}$/.test(ref) && !ref.includes(".."))
    ? null : "Name a branch, tag or commit.";
}

const API = "https://api.github.com";

/** Why an API path is refused, or null for a path on GitHub's REST API. Only GET is ever sent. */
export function vetApiPath(path) {
  if (typeof path !== "string" || !path.startsWith("/") || path.startsWith("//") || path.length > 1_000
    || /[\s\\@#]/.test(path) || path.split("?")[0].split("/").includes("..")) {
    return "Give a path on GitHub's REST API, such as /repos/owner/name/pulls/1/reviews.";
  }
  return new URL(path, API).origin === API ? null : "Only api.github.com can be read.";
}

/** Whether `path`, symlinks followed, is inside `root`. A path that does not exist yet is judged as written. */
export function isInside(root, path) {
  const from = relative(realOf(root), realOf(isAbsolute(path) ? path : resolve(root, path)));
  return from === "" || (!from.startsWith("..") && !isAbsolute(from));
}

/** `path` with symlinks followed as far as it exists; the rest as written. */
function realOf(path) {
  try {
    return realpathSync(path);
  } catch {
    const parent = dirname(path);
    return parent === path ? path : join(realOf(parent), basename(path));
  }
}

const DENY = (reason) => ({
  hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
});

/**
 * The PreToolUse gate. Read, Grep and Glob stay in `cwd` (the PR's checkout) or `clones`; git, clone_repo and
 * github_api pass their vetting. Anything else the agent tries is denied.
 */
export function readOnlyHooks(cwd, clones) {
  const roots = [cwd, clones];
  // No matcher: every tool comes here. A hook that fails blocks its call rather than letting it through.
  return [{
    onFailure: "block",
    hooks: [async (input) => {
      const name = input.tool_name;
      const given = input.tool_input ?? {};
      if (["Read", "Grep", "Glob"].includes(name)) {
        const { file_path: file, path, pattern, glob } = given;
        const target = file ?? path ?? cwd;
        // A Glob pattern, and Grep's file filter, are paths too: absolute or climbing ones reach outside.
        const patterns = [name === "Glob" ? pattern : null, glob].filter((value) => typeof value === "string");
        const escapes = patterns.some((value) => isAbsolute(value) || value.startsWith("~") || value.split(/[\\/]/).includes(".."));
        return roots.some((root) => isInside(root, target)) && !escapes ? {}
          : DENY("Only the checkout and the repos you cloned can be read.");
      }
      const reason = name === `mcp__${SERVER}__git` ? vetGit(given.args) ?? (given.repo === undefined ? null : vetRepo(given.repo))
        : name === `mcp__${SERVER}__clone_repo` ? vetRepo(given.repo) ?? vetRef(given.ref)
          : name === `mcp__${SERVER}__github_api` ? vetApiPath(given.path)
            : "Only reading is allowed.";
      return reason === null ? {} : DENY(reason);
    }],
  }];
}

/** What a tool says back, cut so one answer can't fill the context, and with the token out of it. */
const KEPT = 60_000;

function said(text, token) {
  const clean = token ? String(text).split(token).join("[redacted]") : String(text);
  return clean.length > KEPT ? `${clean.slice(0, KEPT)}\n[cut at ${KEPT} characters]` : clean;
}

const reply = (text, token, isError = false) => ({ content: [{ type: "text", text: said(text, token) }], isError });

/** Git with no config but the repo's own, no pager, no prompt, and none of this process's secrets. */
function gitEnv() {
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: "/nonexistent", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_TERMINAL_PROMPT: "0", GIT_PAGER: "cat", PAGER: "cat", GIT_OPTIONAL_LOCKS: "0",
  };
}

/** The token as one command's header: never on disk, and never in the agent's sight. */
export function authArgs(token) {
  return token ? ["-c", `http.extraHeader=Authorization: Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`] : [];
}

async function runGit(dir, args, token, timeout = 120_000) {
  try {
    const { stdout } = await exec("git", ["-C", dir, ...authArgs(token), ...args], {
      env: gitEnv(), timeout, maxBuffer: 32 * 1024 * 1024,
    });
    return { ok: true, text: stdout };
  } catch (error) {
    // Git's own words, never the command line: that carries the token's header.
    return { ok: false, text: String(error?.stderr ?? "").trim() || `git exited ${error?.code ?? "?"}` };
  }
}

/**
 * The tools, for one question. `prDir` is the PR's checkout of `prRepo`; `clones` is where this person's other repos
 * go. `token`, read only, reaches GitHub; null leaves git on the checkout alone.
 */
export function readTools({ prDir, prRepo, clones, token, locked }) {
  const dirOf = (repo) => (repo === undefined ? prDir : `${clones}/${repo}`);
  const git = tool(
    "git",
    `Runs one read-only git command, without a shell: ${[...GIT_READS].join(", ")}. \`repo\` (owner/name) picks a repo you cloned with clone_repo; leave it out for the PR's checkout of ${prRepo}.`,
    { args: z.array(z.string()).min(1).describe('The subcommand and its arguments, such as ["log", "--oneline", "-20"]'),
      repo: z.string().optional() },
    async ({ args, repo }) => {
      const refused = vetGit(args) ?? (repo === undefined ? null : vetRepo(repo));
      if (refused) {
        return reply(refused, token, true);
      }
      const dir = dirOf(repo);
      if (!existsSync(`${dir}/.git`)) {
        return reply(`${repo} is not cloned yet: clone it with clone_repo first.`, token, true);
      }
      const { ok, text } = await runGit(dir, args, token);
      return reply(text || "(no output)", token, !ok);
    },
  );
  if (!token) {
    return createSdkMcpServer({ name: SERVER, tools: [git], alwaysLoad: true });
  }
  const cloneRepo = tool(
    "clone_repo",
    "Clones a GitHub repo, read only, at its default branch or `ref` (a branch, tag or commit), with its branches and tags. Read it with Read, Grep and Glob at the directory it names, or with git and `repo`. Cloning again updates it.",
    { repo: z.string().describe("owner/name"), ref: z.string().optional() },
    async ({ repo, ref }) => {
      const refused = vetRepo(repo) ?? vetRef(ref);
      if (refused) {
        return reply(refused, token, true);
      }
      const dir = dirOf(repo);
      return locked(dir, async () => {
        if (!existsSync(`${dir}/.git`)) {
          mkdirSync(dir, { recursive: true });
          const made = await runGit(dir, ["init", "-q"], null);
          if (!made.ok) {
            return reply(made.text, token, true);
          }
          await runGit(dir, ["remote", "add", "origin", `https://github.com/${repo}.git`], null);
        }
        const specs = ["+HEAD:refs/remotes/origin/HEAD", "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:refs/tags/*"];
        const fetched = await runGit(dir, ["fetch", "-q", "--filter=blob:none", "origin", ...specs], token, 300_000);
        if (!fetched.ok) {
          return reply(`Could not clone ${repo}: ${fetched.text}`, token, true);
        }
        if (ref && /^[0-9a-f]{40}$/.test(ref)) {
          await runGit(dir, ["fetch", "-q", "--filter=blob:none", "origin", ref], token, 300_000);
        }
        const wanted = ref === undefined ? ["origin/HEAD"] : [`origin/${ref}`, ref];
        for (const target of wanted) {
          const moved = await runGit(dir, ["checkout", "-q", "--force", "--detach", target], token, 300_000);
          if (moved.ok) {
            const head = await runGit(dir, ["rev-parse", "HEAD"], null);
            return reply(`${repo} is at ${head.text.trim()} (${ref ?? "default branch"}), in ${dir}.`, token);
          }
        }
        return reply(`${repo} has no branch, tag or commit ${ref}.`, token, true);
      });
    },
  );
  const githubApi = tool(
    "github_api",
    "GETs one path on GitHub's REST API, read only: PRs, reviews, comments, issues, releases, tags, commits, compare, check runs, workflow runs. Pages with ?per_page=100&page=2.",
    { path: z.string().describe("Such as /repos/owner/name/pulls/1/reviews?per_page=100") },
    async ({ path }) => {
      const refused = vetApiPath(path);
      if (refused) {
        return reply(refused, token, true);
      }
      try {
        const response = await fetch(new URL(path, API), {
          method: "GET", redirect: "manual", signal: AbortSignal.timeout(60_000),
          headers: {
            Accept: "application/vnd.github+json", Authorization: `Bearer ${token}`, "User-Agent": "prhub-ask",
            "X-GitHub-Api-Version": "2022-11-28",
          },
        });
        const where = response.headers.get("location");
        const body = where ? `Redirected to ${where}` : await response.text();
        return reply(`HTTP ${response.status}\n${body}`, token, !response.ok);
      } catch (error) {
        return reply(`GitHub could not be reached: ${error?.message ?? error}`, token, true);
      }
    },
  );
  return createSdkMcpServer({ name: SERVER, tools: [git, cloneRepo, githubApi], alwaysLoad: true });
}

/** The tools' names, for `allowedTools`. */
export function readToolNames(hasToken) {
  return ["git", ...(hasToken ? ["clone_repo", "github_api"] : [])].map((name) => `mcp__${SERVER}__${name}`);
}
