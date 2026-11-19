// Ask's reads beyond the checkout (docs/api.md, "AI on a subscription"): git in a checkout or a cloned repo, cloning
// another repo, and GETs on GitHub's API. Each is a tool this process runs, never a shell: the agent names a git
// subcommand and its arguments, or an API path, and the token stays here. The vetting below gates each call twice, in
// the PreToolUse hook and again in the tool itself.
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { API, GIT_READS, vetApiPath, vetGit, vetRef, vetRepo } from "./vet.mjs";

/** The MCP server's name: its tools are `mcp__prhub__<name>`. */
export const SERVER = "prhub";

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
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: reason,
  },
});

/** Whether `repo` is in `reachable`, the repos this question's token names; null names no limit. GitHub ignores case. */
export function inGrant(repo, reachable) {
  return (
    reachable === null ||
    reachable === undefined ||
    reachable.some((one) => one.toLowerCase() === String(repo).toLowerCase())
  );
}

/**
 * The PreToolUse gate. Read, Grep and Glob stay in `cwd` (the PR's checkout) or `clones`; git, clone_repo and
 * github_api pass their vetting. With `reachable` (hosted: the repos this question's token names), only those clones
 * can be read or made: one cloned while the person could see it is shut once they can't. Anything else is denied.
 */
/** Claude Code's own web tools, which Ask may use: they fetch pages and search, and run nothing here. */
export const WEB_TOOLS = ["WebSearch", "WebFetch"];

export function readOnlyHooks(cwd, clones, reachable = null) {
  const roots = reachable ? [cwd, ...reachable.map((repo) => `${clones}/${repo}`)] : [cwd, clones];
  // No matcher: every tool comes here. A hook that fails blocks its call rather than letting it through.
  return [
    {
      onFailure: "block",
      hooks: [
        async (input) => {
          const name = input.tool_name;
          const given = input.tool_input ?? {};
          if (["Read", "Grep", "Glob"].includes(name)) {
            const { file_path: file, path, pattern, glob } = given;
            const target = file ?? path ?? cwd;
            // A Glob pattern, and Grep's file filter, are paths too: absolute or climbing ones reach outside.
            const patterns = [name === "Glob" ? pattern : null, glob].filter(
              (value) => typeof value === "string",
            );
            const escapes = patterns.some(
              (value) =>
                isAbsolute(value) || value.startsWith("~") || value.split(/[\\/]/).includes(".."),
            );
            const inRoot =
              roots.some((root) => isInside(root, target)) ||
              (reachable !== null &&
                isInside(clones, target) &&
                cloneInGrant(clones, target, reachable));
            return inRoot && !escapes
              ? {}
              : DENY("Only the checkout and the repos you cloned can be read.");
          }
          // The web, open by Jai's choice (2026-11-13: "we need feature richness"): WebFetch can put what the agent read in a
          // URL it fetches, so a prompt in a PR could send code out. The tokens can't go: no tool reads them.
          if (WEB_TOOLS.includes(name)) {
            return {};
          }
          // A draft for the reviewer's phone: it reaches nothing, and posts nothing.
          if (
            [`draft_review`, `github_act`, `linear_act`].some(
              (one) => name === `mcp__${SERVER}__${one}`,
            )
          ) {
            return {};
          }
          const granted = (repo) => (inGrant(repo, reachable) ? null : cantAccess(repo));
          const reason =
            name === `mcp__${SERVER}__git`
              ? (vetGit(given.args) ??
                (given.repo === undefined ? null : (vetRepo(given.repo) ?? granted(given.repo))))
              : name === `mcp__${SERVER}__clone_repo`
                ? (vetRepo(given.repo) ?? vetRef(given.ref) ?? granted(given.repo))
                : name === `mcp__${SERVER}__github_api`
                  ? vetApiPath(given.path)
                  : "Only reading is allowed.";
          return reason === null ? {} : DENY(reason);
        },
      ],
    },
  ];
}

/** Whether a path under `clones` is in a repo of `reachable`, matched without case as GitHub names repos. */
function cloneInGrant(clones, target, reachable) {
  const [owner, name] = relative(
    realOf(clones),
    realOf(isAbsolute(target) ? target : resolve(clones, target)),
  ).split(/[\\/]/);
  return Boolean(owner && name) && inGrant(`${owner}/${name}`, reachable);
}

/** What a tool says back, cut so one answer can't fill the context, and with both tokens out of it. */
const KEPT = 60_000;

function said(text, token) {
  const clean = [token, process.env.CLAUDE_CODE_OAUTH_TOKEN].reduce(
    (kept, secret) => (secret ? kept.split(secret).join("[redacted]") : kept),
    String(text),
  );
  return clean.length > KEPT ? `${clean.slice(0, KEPT)}\n[cut at ${KEPT} characters]` : clean;
}

/** What a repo the token can't reach answers: GitHub's 404 says nothing about whether it exists. */
export function cantAccess(repo) {
  return `You can't access ${repo}: the reviewer can't see it, or the GitHub App isn't installed on it. Say so; don't guess what it holds.`;
}

const reply = (text, token, isError = false) => ({
  content: [{ type: "text", text: said(text, token) }],
  isError,
});

/**
 * Set on every git command, over anything a repo's config says: no fsmonitor or hook program, no pager or editor, no
 * ssh, and https the one protocol (a blobless clone fetches what it lacks over it).
 */
export const SAFE_GIT = [
  "core.fsmonitor=false",
  "core.hooksPath=/dev/null",
  "core.pager=cat",
  "core.editor=false",
  "core.sshCommand=false",
  "protocol.allow=never",
  "protocol.https.allow=always",
].flatMap((setting) => ["-c", setting]);

/** Put after a read subcommand: no external diff or textconv program, whatever the repo's config names. */
const NO_PROGRAMS = {
  log: ["--no-ext-diff", "--no-textconv"],
  show: ["--no-ext-diff", "--no-textconv"],
  diff: ["--no-ext-diff", "--no-textconv"],
  blame: ["--no-textconv"],
  grep: ["--no-textconv"],
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
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: "/nonexistent",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_TERMINAL_PROMPT: "0",
    GIT_PAGER: "cat",
    PAGER: "cat",
    GIT_OPTIONAL_LOCKS: "0",
  };
}

/** The token as one command's header: never on disk, and never in the agent's sight. */
export function authArgs(token) {
  return token
    ? [
        "-c",
        `http.extraHeader=Authorization: Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`,
      ]
    : [];
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
      env: gitEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      timeout,
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
      done({
        ok: false,
        text: Buffer.concat(err).toString().trim() || `git exited ${code ?? signal ?? "?"}`,
      });
    });
  });
}

/**
 * The tools, for one question. `prDir` is the PR's checkout of `prRepo`; `clones` is where this person's other repos
 * go; `scope` holds both, and git never runs outside it. `token`, read only, reaches GitHub; null leaves git on the
 * checkout alone. `reachable`, hosted, names the repos the token reaches: no other clone is read or made.
 */
export function readTools({
  prDir,
  prRepo,
  clones,
  scope,
  token,
  locked,
  reachable = null,
  onDraft = () => {},
  onAct = () => {},
  onLinear = () => {},
}) {
  const draftReview = draftReviewTool(onDraft);
  const act = actTool(onAct);
  const linear = linearActTool(onLinear);
  const dirOf = (repo) => (repo === undefined ? prDir : `${clones}/${repo}`);
  const git = tool(
    "git",
    `Runs one read-only git command, without a shell: ${[...GIT_READS.keys()].join(", ")}, each with a fixed set of options; a refused option says which ones it takes. \`repo\` (owner/name) picks a repo you cloned with clone_repo; leave it out for the PR's checkout of ${prRepo}.`,
    {
      args: z
        .array(z.string())
        .min(1)
        .describe('The subcommand and its arguments, such as ["log", "--oneline", "-20"]'),
      repo: z.string().optional(),
    },
    async ({ args, repo }) => {
      const refused =
        vetGit(args) ??
        (repo === undefined
          ? null
          : (vetRepo(repo) ?? (inGrant(repo, reachable) ? null : cantAccess(repo))));
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
      const { ok, text } = await runGit(
        real.dir,
        [command, ...(NO_PROGRAMS[command] ?? []), ...rest],
        token,
      );
      return reply(text || "(no output)", token, !ok);
    },
  );
  if (!token) {
    return createSdkMcpServer({
      name: SERVER,
      tools: [git, draftReview, act, linear],
      alwaysLoad: true,
    });
  }
  const cloneRepo = tool(
    "clone_repo",
    "Clones a GitHub repo, read only, at its default branch or `ref` (a branch, tag or commit), with its branches and tags. Read it with Read, Grep and Glob at the directory it names, or with git and `repo`. Cloning again updates it.",
    { repo: z.string().describe("owner/name"), ref: z.string().optional() },
    async ({ repo, ref }) => {
      const refused =
        vetRepo(repo) ?? vetRef(ref) ?? (inGrant(repo, reachable) ? null : cantAccess(repo));
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
        const specs = [
          "+HEAD:refs/remotes/origin/HEAD",
          "+refs/heads/*:refs/remotes/origin/*",
          "+refs/tags/*:refs/tags/*",
        ];
        const fetched = await runGit(
          dir,
          ["fetch", "-q", "--filter=blob:none", "origin", ...specs],
          token,
          300_000,
        );
        if (!fetched.ok) {
          return reply(
            `Could not clone ${repo}: ${fetched.text}\n${cantAccess(repo)}`,
            token,
            true,
          );
        }
        if (ref && /^[0-9a-f]{40}$/.test(ref)) {
          await runGit(dir, ["fetch", "-q", "--filter=blob:none", "origin", ref], token, 300_000);
        }
        const wanted = ref === undefined ? ["origin/HEAD"] : [`origin/${ref}`, ref];
        for (const target of wanted) {
          const moved = await runGit(
            dir,
            ["checkout", "-q", "--force", "--detach", target],
            token,
            300_000,
          );
          if (moved.ok) {
            lockConfig(dir);
            const head = await runGit(dir, ["rev-parse", "HEAD"], null);
            return reply(
              `${repo} is at ${head.text.trim()} (${ref ?? "default branch"}), in ${dir}.`,
              token,
            );
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
    },
  );
  return createSdkMcpServer({
    name: SERVER,
    tools: [git, cloneRepo, githubApi, draftReview, act, linear],
    alwaysLoad: true,
  });
}

/** The most line comments one draft holds: a review past this is a wall, not a review. */
export const DRAFT_COMMENTS = 30;

/**
 * A review the reviewer asked for, as a draft: it never reaches GitHub from here. `onDraft` keeps the newest, the
 * container hands it to the Worker with the answer, and the reviewer posts it from the phone, as themselves.
 */
function draftReviewTool(onDraft) {
  return tool(
    "draft_review",
    `Drafts a review of this PR for the reviewer to post: a verdict, the review's words, and up to ${DRAFT_COMMENTS} line comments. It posts nothing: the reviewer reads it on their phone and posts it themselves. Call it only when they ask you to write, draft or give a review, approve, or request changes; a later call replaces the draft. Each comment is on a line the PR's diff shows: \`line\` is the new file's line number with side RIGHT, or the old file's with side LEFT for a removed line. GitHub refuses the whole review when one comment is on any other line.`,
    {
      event: z.enum(["APPROVE", "REQUEST_CHANGES", "COMMENT"]),
      body: z.string().max(20_000).describe("The review's own words, in GitHub's Markdown"),
      comments: z
        .array(
          z.object({
            path: z.string().min(1),
            line: z.number().int().positive(),
            side: z.enum(["LEFT", "RIGHT"]),
            body: z.string().min(1).max(5_000),
          }),
        )
        .max(DRAFT_COMMENTS)
        .default([]),
    },
    async ({ event, body, comments }) => {
      onDraft({ event, body, comments });
      const lines = comments.length === 1 ? "1 line comment" : `${comments.length} line comments`;
      return reply(
        `Drafted: ${event} with ${lines}. Nothing is posted: the reviewer sees the draft under your answer and posts it. Say in one line what the draft does; don't repeat it.`,
        null,
      );
    },
  );
}

/** The most actions one turn takes on GitHub. */
export const ACTS = 10;

/**
 * Acting on the PR as the reviewer, as they asked: the container has no token that writes, so each action goes to the
 * Worker with the answer, and the Worker posts it with the reviewer's own GitHub sign-in (`POST …/write`'s way).
 */
function actTool(onAct) {
  return tool(
    "github_act",
    `Acts on this PR on GitHub as the reviewer, with their own permissions, once your turn ends: the chat then says what GitHub took or refused. Only when the reviewer asked for it in their message. One action per call, up to ${ACTS} a turn:
- {"kind":"review","event":"APPROVE"|"REQUEST_CHANGES"|"COMMENT","body":"…","commit":"<head sha>","comments":[{"path":"…","line":12,"side":"RIGHT","body":"…"}]}
- {"kind":"comment","body":"…"}: a comment on the PR
- {"kind":"line","body":"…","commit":"<head sha>","path":"…","line":12,"side":"RIGHT"|"LEFT"}
- {"kind":"merge","method":"merge"|"squash"|"rebase","commit":"<head sha>"}
- {"kind":"update_branch","commit":"<head sha>"}
A line comment must be on a line the diff shows.`,
    { action: z.record(z.string(), z.unknown()).describe("One action, as above") },
    async ({ action }) => {
      onAct(action);
      return reply(
        "Queued: it goes to GitHub as the reviewer when your turn ends, and the chat shows the result. Don't say it is done yet.",
        null,
      );
    },
  );
}

/** The most Linear comments one turn proposes. */
export const LINEAR_ACTS = 3;

/**
 * A comment on one of the PR's Linear tickets, as the reviewer, as they asked: the container has no Linear key, so it
 * goes to the Worker with the answer. The reviewer sees it as a card and posts it from the phone; the Worker posts it
 * with their own Linear key, its @mentions made Linear's own.
 */
function linearActTool(onLinear) {
  return tool(
    "linear_act",
    `Proposes a comment on one of this PR's Linear tickets, posted as the reviewer once they confirm it on their phone. Only when the reviewer asked for it in their message ("tag Octbot on the ticket", "comment on the ticket"). \`issue\` is a ticket key the PR names, such as ENG-12. Write @Name for each person or agent to mention, as the reviewer named them ("@Octbot"): the Worker finds them in Linear. Up to ${LINEAR_ACTS} a turn.`,
    {
      issue: z
        .string()
        .regex(/^[A-Za-z][A-Za-z0-9]{0,9}-\d+$/)
        .describe("The ticket's key, such as ENG-12"),
      body: z.string().min(1).max(10_000).describe("The comment, in Markdown, with @Name mentions"),
    },
    async ({ issue, body }) => {
      onLinear({ issue: issue.toUpperCase(), body });
      return reply(
        `Proposed: a comment on ${issue.toUpperCase()}. Nothing is posted: the reviewer sees it under your answer and posts it. Say in one line what it asks; don't say it is posted.`,
        null,
      );
    },
  );
}

/** The tools' names, for `allowedTools`. */
export function readToolNames(hasToken) {
  return [
    "git",
    ...(hasToken ? ["clone_repo", "github_api"] : []),
    "draft_review",
    "github_act",
    "linear_act",
  ].map((name) => `mcp__${SERVER}__${name}`);
}
