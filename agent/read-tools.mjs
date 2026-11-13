// Ask's reads beyond the checkout (docs/api.md, "AI on a subscription"): git in a checkout or a cloned repo, cloning
// another repo, and GETs on GitHub's API. Each is a tool this process runs, never a shell: the agent names a git
// subcommand and its arguments, or an API path, and the token stays here. The vetting below gates each call twice, in
// the PreToolUse hook and again in the tool itself.
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

/** The MCP server's name: its tools are `mcp__prhub__<name>`. */
export const SERVER = "prhub";

const words = (text) => text.trim().split(/\s+/);

/**
 * Each subcommand's options, in three lists:
 * - `flags`: taken alone. An option whose value is optional in git (`--pretty`, `--abbrev`, `--stat`, `--decorate`,
 *   `-M`) is here when bare: git never takes the next argument as its value, so neither may the vetting.
 * - `attached`: taken only with the value in the same argument, `--name=value` or `-xvalue`.
 * - `separate`: options whose value git requires, which may also take the next argument as it. That argument is
 *   vetted: it must not start with `-` and must not be a path out of the repo.
 * No option on any list names a file to read or write, or a program to run.
 */
const DIFF = {
  flags: words(`-p --patch --no-patch -s --stat --shortstat --numstat --name-only --name-status --summary --raw -w -b
    --ignore-all-space --ignore-space-change --no-renames -M -R --patience --histogram --minimal --no-color --word-diff
    --full-index --binary --abbrev`),
  attached: words("-U --unified --diff-filter --stat-width --abbrev"),
  separate: words("--diff-filter"),
};

/** A history. `-S` and `-G` search it for a string, and `-L` names a range of a file in the repo's history. */
const LOG = {
  flags: [...DIFF.flags, ...words(`--oneline --graph --decorate --no-decorate --all --branches --tags --remotes --merges
    --no-merges --first-parent --reverse --date-order --topo-order --author-date-order --abbrev-commit
    --no-abbrev-commit --full-history --simplify-merges --ancestry-path --left-right --cherry-pick --cherry-mark
    --boundary --follow -i --regexp-ignore-case --all-match --invert-grep -E --extended-regexp -F --fixed-strings -m
    --cc --full-diff --source --use-mailmap --parents --children --no-walk --count --notes --no-notes --pretty`)],
  attached: [...DIFF.attached, ...words(`-n --max-count --skip --since --until --after --before --author --committer
    --grep -S -G -L --format --pretty --date --min-parents --max-parents --decorate-refs`)],
  separate: [...DIFF.separate, ...words(`-n --max-count --skip --since --until --after --before --author --committer
    --grep -S -G -L --date --min-parents --max-parents`)],
  counts: true,
};

const none = { flags: [], attached: [], separate: [] };

/**
 * Git subcommands that only read, each with the only options it takes. An option not listed is refused, and so is
 * every abbreviation: `--ignore-revs-f` is not `--ignore-revs-file`, it is unknown.
 */
export const GIT_READS = new Map(Object.entries({
  log: LOG,
  show: LOG,
  "rev-list": LOG,
  shortlog: { flags: words("-s --summary -n --numbered -e --email --all --merges --no-merges"),
    attached: words("--since --until --after --before --author --max-count --format"),
    separate: words("--since --until --after --before --author --max-count"), counts: true },
  diff: { ...DIFF, flags: [...DIFF.flags, "--cached", "--staged", "--merge-base"] },
  grep: { flags: words(`-n --line-number -i --ignore-case -w --word-regexp -v --invert-match -l --files-with-matches
    -L --files-without-match --count -h -H --full-name -E --extended-regexp -F --fixed-strings -G --basic-regexp
    -P --perl-regexp -I --heading --break --cached --all-match --and --or --not --only-matching --column -p
    --show-function -W --function-context -a --text`),
    attached: words("-e -A -B -C --context --after-context --before-context --max-depth -m --max-count"),
    separate: words("-e -A -B -C --context --after-context --before-context --max-depth -m --max-count") },
  blame: { flags: words("-l -s -e --show-email -w -M -C --porcelain --line-porcelain -t --root --show-name --show-number -f -n"),
    attached: words("-L"), separate: words("-L") },
  describe: { flags: words("--tags --all --always --long --contains --exact-match --first-parent --abbrev"),
    attached: words("--abbrev --match --exclude --candidates"), separate: words("--match --exclude --candidates") },
  "rev-parse": { ...none, flags: words("--short --abbrev-ref --verify -q --quiet --symbolic-full-name --is-shallow-repository") },
  "merge-base": { ...none, flags: words("--is-ancestor --all --octopus --independent") },
  "name-rev": { ...none, flags: words("--tags --name-only --always") },
  "ls-files": { ...none, flags: words("--cached --stage -s --full-name --error-unmatch --deleted --modified") },
  "ls-tree": { flags: words("-r -t -d --name-only --name-status -l --long --full-name --full-tree --abbrev"),
    attached: words("--abbrev"), separate: [] },
  "cat-file": { ...none, flags: words("-t -s -p -e") },
  "for-each-ref": { flags: [],
    attached: words("--contains --no-contains --merged --no-merged --points-at --sort --format --count"),
    separate: words("--contains --no-contains --merged --no-merged --points-at --sort --format --count") },
}));

/**
 * Writers and runners, refused wherever they appear, whatever the lists above say: a last guard if a list is ever
 * wrong. `-c` and `-o` here also take every option that starts with them, so grep counts with `--count`.
 */
const NEVER = /^(?:--output|-o|--ext-diff|--textconv|--open-files-in-pager|-O|--exec|--upload-pack|--config|-c|--git-dir|--work-tree|--namespace)/;

/** A path argument as given: none absolute, from home, or climbing. */
function outsidePath(arg) {
  return isAbsolute(arg) || arg.startsWith("~") || arg.split(/[\\/]/).includes("..");
}

/**
 * Why a git call is refused, or null when it only reads. `args` start with the subcommand. Every option must be on the
 * subcommand's lists, whole (`GIT_READS`). Everything else is a revision or a path, and a path stays inside the repo.
 */
export function vetGit(args) {
  if (!Array.isArray(args) || args.length === 0 || args.some((arg) => typeof arg !== "string")) {
    return "Give git a subcommand and its arguments, as a list of strings.";
  }
  const [command, ...rest] = args;
  const allowed = GIT_READS.get(command);
  if (!allowed) {
    return `git ${command} is not allowed. Allowed: ${[...GIT_READS.keys()].join(", ")}.`;
  }
  const writer = rest.find((arg) => NEVER.test(arg));
  if (writer !== undefined) {
    return `${writer.split("=")[0]} is never allowed: it writes a file, runs a program or changes git's config.`;
  }
  const refusal = `git ${command} takes only: ${[...allowed.flags, ...allowed.attached.map((name) => `${name}=…`)].join(" ")}.`;
  let paths = false;
  for (let at = 0; at < rest.length; at++) {
    const arg = rest[at];
    if (/[\0-\x1f]/.test(arg)) {
      return "An argument holds a control character.";
    }
    if (paths || !arg.startsWith("-") || arg === "-") {
      if (outsidePath(arg)) {
        return "Paths stay inside the repo: no absolute paths, ~ or ..";
      }
      continue;
    }
    if (arg === "--") {
      paths = true;
      continue;
    }
    if ((allowed.counts && /^-\d+$/.test(arg)) || allowed.flags.includes(arg)) {
      continue;
    }
    const long = /^(--[a-z][a-z-]*)=/.exec(arg);
    if (long) {
      if (allowed.attached.includes(long[1])) {
        continue;
      }
      return refusal;
    }
    if (allowed.separate.includes(arg)) {
      const value = rest[at + 1];
      if (value === undefined || value.startsWith("-") || outsidePath(value)) {
        return `${arg} takes a value in the next argument, which can't be an option or a path out of the repo.`;
      }
      at++;
      continue;
    }
    const short = /^(-[A-Za-z])./.exec(arg);
    if (short && !arg.startsWith("--") && allowed.attached.includes(short[1])) {
      continue;
    }
    return refusal;
  }
  return null;
}

/**
 * The real directory for a git call: `dir` with symlinks followed, inside `scope`, and each argument that names an
 * existing file resolving inside it. A repo's committed symlink can't point git elsewhere.
 */
export function realGitDir(dir, scope, args) {
  const real = realOf(dir);
  if (!isInside(scope, real)) {
    return { refused: "That repo is outside this person's files." };
  }
  for (const arg of args.slice(1)) {
    const candidate = resolve(real, arg);
    if (!arg.startsWith("-") && existsSync(candidate) && !isInside(real, candidate)) {
      return { refused: `${arg} is a link out of the repo.` };
    }
  }
  return { dir: real };
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

/** Whether `repo` is in `reachable`, the repos this question's token names; null names no limit. GitHub ignores case. */
export function inGrant(repo, reachable) {
  return reachable === null || reachable === undefined
    || reachable.some((one) => one.toLowerCase() === String(repo).toLowerCase());
}

/**
 * The PreToolUse gate. Read, Grep and Glob stay in `cwd` (the PR's checkout) or `clones`; git, clone_repo and
 * github_api pass their vetting. With `reachable` (hosted: the repos this question's token names), only those clones
 * can be read or made: one cloned while the person could see it is shut once they can't. Anything else is denied.
 */
export function readOnlyHooks(cwd, clones, reachable = null) {
  const roots = reachable ? [cwd, ...reachable.map((repo) => `${clones}/${repo}`)] : [cwd, clones];
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
        const inRoot = roots.some((root) => isInside(root, target))
          || (reachable !== null && isInside(clones, target) && cloneInGrant(clones, target, reachable));
        return inRoot && !escapes ? {}
          : DENY("Only the checkout and the repos you cloned can be read.");
      }
      const granted = (repo) => (inGrant(repo, reachable) ? null : cantAccess(repo));
      const reason = name === `mcp__${SERVER}__git`
        ? vetGit(given.args) ?? (given.repo === undefined ? null : vetRepo(given.repo) ?? granted(given.repo))
        : name === `mcp__${SERVER}__clone_repo` ? vetRepo(given.repo) ?? vetRef(given.ref) ?? granted(given.repo)
          : name === `mcp__${SERVER}__github_api` ? vetApiPath(given.path)
            : "Only reading is allowed.";
      return reason === null ? {} : DENY(reason);
    }],
  }];
}

/** Whether a path under `clones` is in a repo of `reachable`, matched without case as GitHub names repos. */
function cloneInGrant(clones, target, reachable) {
  const [owner, name] = relative(realOf(clones), realOf(isAbsolute(target) ? target : resolve(clones, target))).split(/[\\/]/);
  return Boolean(owner && name) && inGrant(`${owner}/${name}`, reachable);
}

/** What a tool says back, cut so one answer can't fill the context, and with both tokens out of it. */
const KEPT = 60_000;

function said(text, token) {
  const clean = [token, process.env.CLAUDE_CODE_OAUTH_TOKEN].reduce(
    (kept, secret) => (secret ? kept.split(secret).join("[redacted]") : kept), String(text));
  return clean.length > KEPT ? `${clean.slice(0, KEPT)}\n[cut at ${KEPT} characters]` : clean;
}

/** What a repo the token can't reach answers: GitHub's 404 says nothing about whether it exists. */
export function cantAccess(repo) {
  return `You can't access ${repo}: the reviewer can't see it, or the GitHub App isn't installed on it. Say so; don't guess what it holds.`;
}

const reply = (text, token, isError = false) => ({ content: [{ type: "text", text: said(text, token) }], isError });

/**
 * Set on every git command, over anything a repo's config says: no fsmonitor or hook program, no pager or editor, no
 * ssh, and https the one protocol (a blobless clone fetches what it lacks over it).
 */
export const SAFE_GIT = ["core.fsmonitor=false", "core.hooksPath=/dev/null", "core.pager=cat", "core.editor=false",
  "core.sshCommand=false", "protocol.allow=never", "protocol.https.allow=always"].flatMap((setting) => ["-c", setting]);

/** Put after a read subcommand: no external diff or textconv program, whatever the repo's config names. */
const NO_PROGRAMS = {
  log: ["--no-ext-diff", "--no-textconv"], show: ["--no-ext-diff", "--no-textconv"], diff: ["--no-ext-diff", "--no-textconv"],
  blame: ["--no-textconv"], grep: ["--no-textconv"],
};

/** A repo's config, read only once git has set it up: a defence beside `SAFE_GIT`, as no read tool writes it. */
export function lockConfig(dir) {
  try {
    chmodSync(`${dir}/.git/config`, 0o444);
  } catch {}
}

/** Git with no config but the repo's own, no pager, no prompt, and none of this process's secrets. */
export function gitEnv() {
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: "/nonexistent", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_TERMINAL_PROMPT: "0", GIT_PAGER: "cat", PAGER: "cat", GIT_OPTIONAL_LOCKS: "0",
  };
}

/** The token as one command's header: never on disk, and never in the agent's sight. */
export function authArgs(token) {
  return token ? ["-c", `http.extraHeader=Authorization: Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`] : [];
}

/** Most bytes of output kept from one git command: the rest is dropped and the command stopped. */
const GIT_OUTPUT_MAX = 8 * 1024 * 1024;

/**
 * Git in `dir` with an empty stdin, so a command that reads it (`cat-file --batch`, `shortlog` with no revision) ends
 * at once. Git's own words on a failure, never the command line: that carries the token's header.
 */
export function runGit(dir, args, token, timeout = 120_000) {
  return new Promise((done) => {
    const child = spawn("git", ["-C", dir, ...SAFE_GIT, ...authArgs(token), ...args], {
      env: gitEnv(), stdio: ["ignore", "pipe", "pipe"], timeout,
    });
    const out = [];
    const err = [];
    let size = 0;
    child.stdout.on("data", (chunk) => {
      size += chunk.length;
      if (size <= GIT_OUTPUT_MAX) {
        out.push(chunk);
      } else {
        child.kill();
      }
    });
    child.stderr.on("data", (chunk) => err.push(chunk));
    child.on("error", (error) => done({ ok: false, text: `git could not run: ${error.message}` }));
    child.on("close", (code, signal) => {
      const stdout = Buffer.concat(out).toString();
      if (code === 0 || (size > GIT_OUTPUT_MAX && stdout)) {
        done({ ok: true, text: stdout });
        return;
      }
      done({ ok: false, text: Buffer.concat(err).toString().trim() || `git exited ${code ?? signal ?? "?"}` });
    });
  });
}

/**
 * The tools, for one question. `prDir` is the PR's checkout of `prRepo`; `clones` is where this person's other repos
 * go; `scope` holds both, and git never runs outside it. `token`, read only, reaches GitHub; null leaves git on the
 * checkout alone. `reachable`, hosted, names the repos the token reaches: no other clone is read or made.
 */
export function readTools({ prDir, prRepo, clones, scope, token, locked, reachable = null }) {
  const dirOf = (repo) => (repo === undefined ? prDir : `${clones}/${repo}`);
  const git = tool(
    "git",
    `Runs one read-only git command, without a shell: ${[...GIT_READS.keys()].join(", ")}, each with a fixed set of options; a refused option says which ones it takes. \`repo\` (owner/name) picks a repo you cloned with clone_repo; leave it out for the PR's checkout of ${prRepo}.`,
    { args: z.array(z.string()).min(1).describe('The subcommand and its arguments, such as ["log", "--oneline", "-20"]'),
      repo: z.string().optional() },
    async ({ args, repo }) => {
      const refused = vetGit(args) ?? (repo === undefined ? null
        : vetRepo(repo) ?? (inGrant(repo, reachable) ? null : cantAccess(repo)));
      if (refused) {
        return reply(refused, token, true);
      }
      if (!existsSync(`${dirOf(repo)}/.git`)) {
        return reply(`${repo} is not cloned yet: clone it with clone_repo first.`, token, true);
      }
      const real = realGitDir(dirOf(repo), scope, args);
      if (real.refused) {
        return reply(real.refused, token, true);
      }
      const [command, ...rest] = args;
      const { ok, text } = await runGit(real.dir, [command, ...(NO_PROGRAMS[command] ?? []), ...rest], token);
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
      const refused = vetRepo(repo) ?? vetRef(ref) ?? (inGrant(repo, reachable) ? null : cantAccess(repo));
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
          return reply(`Could not clone ${repo}: ${fetched.text}\n${cantAccess(repo)}`, token, true);
        }
        if (ref && /^[0-9a-f]{40}$/.test(ref)) {
          await runGit(dir, ["fetch", "-q", "--filter=blob:none", "origin", ref], token, 300_000);
        }
        const wanted = ref === undefined ? ["origin/HEAD"] : [`origin/${ref}`, ref];
        for (const target of wanted) {
          const moved = await runGit(dir, ["checkout", "-q", "--force", "--detach", target], token, 300_000);
          if (moved.ok) {
            lockConfig(dir);
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
        const named = /^\/repos\/([^/?]+\/[^/?]+)/.exec(path)?.[1];
        const denied = (response.status === 404 || response.status === 403) && named && named !== prRepo
          ? `\n${cantAccess(named)}` : "";
        return reply(`HTTP ${response.status}\n${body}${denied}`, token, !response.ok);
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
