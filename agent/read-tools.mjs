// Ask's reads beyond the checkout (docs/api.md, "AI on a subscription"): git in a checkout or a cloned repo, cloning
// another repo, and GETs on GitHub's API. Each is a tool this process runs, never a shell: the agent names a git
// subcommand and its arguments, or an API path, and the token stays here. The vetting below gates each call twice, in
// the PreToolUse hook and again in the tool itself.
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, realpathSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import {
  cantAccess,
  cloneRefusal,
  gitRefusal,
  isInside as isInsideBy,
  readOnlyHooks as gate,
  SERVER,
} from "./gate.mjs";
import {
  ACTS,
  actHandler,
  draftReviewHandler,
  githubApiHandler,
  LINEAR_ACTS,
  linearActHandler,
  linearReadHandler,
  reply,
} from "./replies.mjs";
import {
  checkoutTargets,
  DRAFT_COMMENTS,
  GIT_READS,
  gitArgv,
  gitCommand,
  gitEnv,
  INPUTS,
} from "./vet.mjs";

export { readToolNames, SERVER, WEB_TOOLS } from "./gate.mjs";
export { ACTS, LINEAR_ACTS } from "./replies.mjs";

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

/** Whether `path`, symlinks followed on disk, is inside `root`. A path that does not exist yet is judged as written. */
export function isInside(root, path) {
  return isInsideBy(root, path, realOf);
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

/** The PreToolUse gate (`gate.mjs`), with symlinks followed on disk. */
export function readOnlyHooks(cwd, clones, reachable = null, realpath = realOf) {
  return gate(cwd, clones, reachable, realpath);
}

/** A repo's config, read only once git has set it up: a defence beside `SAFE_GIT` (vet.mjs), as no read tool writes it. */
export function lockConfig(dir) {
  try {
    chmodSync(`${dir}/.git/config`, 0o444);
  } catch {}
}

/** Most bytes of output kept from one git command: the rest is dropped and the command stopped. */
const GIT_OUTPUT_MAX = 8 * 1024 * 1024;

/**
 * Git in `dir` with an empty stdin, so a command that reads it (`cat-file --batch`, `shortlog` with no revision) ends
 * at once. Git's own words on a failure, never the command line: that carries the token's header.
 */
export function runGit(dir, args, token, timeout = 120_000) {
  return new Promise((done) => {
    const child = spawn("git", gitArgv(dir, args, token), {
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
  askWorker = null,
}) {
  const draftReview = draftReviewTool(onDraft);
  const act = actTool(onAct);
  const linear = linearActTool(onLinear);
  // Linear's reads exist only when the Worker said it answers them: it holds the key, this process never does.
  const linearReads = askWorker ? linearReadTools(askWorker) : [];
  const dirOf = (repo) => (repo === undefined ? prDir : `${clones}/${repo}`);
  const git = tool(
    "git",
    `Runs one read-only git command, without a shell: ${[...GIT_READS.keys()].join(", ")}, each with a fixed set of options; a refused option says which ones it takes. \`repo\` (owner/name) picks a repo you cloned with clone_repo; leave it out for the PR's checkout of ${prRepo}.`,
    INPUTS.git,
    async ({ args, repo }) => {
      const refused = gitRefusal(args, repo, reachable);
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
      const { ok, text } = await runGit(real.dir, gitCommand(args), token);
      return reply(text || "(no output)", token, !ok);
    },
  );
  if (!token) {
    return createSdkMcpServer({
      name: SERVER,
      tools: [git, draftReview, act, linear, ...linearReads],
      alwaysLoad: true,
    });
  }
  const cloneRepo = tool(
    "clone_repo",
    "Clones a GitHub repo, read only, at its default branch or `ref` (a branch, tag or commit), with its branches and tags. Read it with Read, Grep and Glob at the directory it names, or with git and `repo`. Cloning again updates it.",
    INPUTS.clone_repo,
    async ({ repo, ref }) => {
      const refused = cloneRefusal(repo, ref, reachable);
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
        const { fetch: commit, targets } = checkoutTargets(ref);
        if (commit) {
          await runGit(
            dir,
            ["fetch", "-q", "--filter=blob:none", "origin", commit],
            token,
            300_000,
          );
        }
        for (const target of targets) {
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
    INPUTS.github_api,
    githubApiHandler({ token, prRepo }),
  );
  return createSdkMcpServer({
    name: SERVER,
    tools: [git, cloneRepo, githubApi, draftReview, act, linear, ...linearReads],
    alwaysLoad: true,
  });
}

/**
 * A review the reviewer asked for, as a draft: it never reaches GitHub from here. `onDraft` keeps the newest, the
 * container hands it to the Worker with the answer, and the reviewer posts it from the phone, as themselves.
 */
function draftReviewTool(onDraft) {
  return tool(
    "draft_review",
    `Drafts a review of this PR for the reviewer to post: a verdict, the review's words, and up to ${DRAFT_COMMENTS} line comments. It posts nothing: the reviewer reads it on their phone and posts it themselves. Call it only when they ask you to write, draft or give a review, approve, or request changes; a later call replaces the draft. Each comment is on a line the PR's diff shows: \`line\` is the new file's line number with side RIGHT, or the old file's with side LEFT for a removed line. GitHub refuses the whole review when one comment is on any other line.`,
    INPUTS.draft_review,
    draftReviewHandler(onDraft),
  );
}

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
    INPUTS.github_act,
    actHandler(onAct),
  );
}

/** Reading Linear: both tools ask the Worker, which runs a fixed query with the reviewer's own key. Neither writes. */
function linearReadTools(askWorker) {
  return [
    tool(
      "linear_issue",
      "Reads one Linear ticket by its key, such as ENG-12, read only: title, description, state, owner (assignee), the agent it is delegated to, labels, parent, sub-issues and linked pull requests. With `comments` true, its newest comments too. The PR's own tickets are already in your instructions: use this for their comments, or for another ticket.",
      INPUTS.linear_issue,
      linearReadHandler(askWorker, "issue"),
    ),
    tool(
      "linear_search",
      "Finds Linear tickets by a key or by words, read only: up to 10, each with its key, title, state and owner. Read one in full with linear_issue.",
      INPUTS.linear_search,
      linearReadHandler(askWorker, "search"),
    ),
  ];
}

/**
 * A comment on one of the PR's Linear tickets, as the reviewer, as they asked: the container has no Linear key, so it
 * goes to the Worker with the answer. The reviewer sees it as a card and posts it from the phone; the Worker posts it
 * with their own Linear key, its @mentions made Linear's own.
 */
function linearActTool(onLinear) {
  return tool(
    "linear_act",
    `Proposes a comment on one of this PR's Linear tickets, posted as the reviewer once they confirm it on their phone. Only when the reviewer asked for it in their message ("tag Octbot on the ticket", "comment on the ticket"). \`issue\` is a ticket key the PR names, such as ENG-12. Write @Name for each person or agent to mention, as the reviewer named them ("@Octbot"): the Worker finds them in Linear. Up to ${LINEAR_ACTS} a turn.`,
    INPUTS.linear_act,
    linearActHandler(onLinear),
  );
}
