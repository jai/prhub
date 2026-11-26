// The PreToolUse gate and the tools' names: decided without touching anything. Where a path is judged, the caller
// hands in `realpath`, which follows symlinks (read-tools.mjs passes the disk's own); nothing here reads the disk.
import { isAbsolute, relative, resolve } from "node:path";
import { outsidePath, vetApiPath, vetGit, vetRef, vetRepo } from "./vet.mjs";

/** The MCP server's name: its tools are `mcp__prhub__<name>`. */
export const SERVER = "prhub";

/** Claude Code's own web tools, which Ask may use: they fetch pages and search, and run nothing here. */
export const WEB_TOOLS = ["WebSearch", "WebFetch"];

/** Whether `path`, followed by `realpath`, is inside `root`. A relative `path` is taken from `root`. */
export function isInside(root, path, realpath) {
  const from = relative(realpath(root), realpath(isAbsolute(path) ? path : resolve(root, path)));
  return from === "" || (!from.startsWith("..") && !isAbsolute(from));
}

/** Whether `repo` is in `reachable`, the repos this question's token names; null names no limit. GitHub ignores case. */
export function inGrant(repo, reachable) {
  return (
    reachable === null ||
    reachable === undefined ||
    reachable.some((one) => one.toLowerCase() === String(repo).toLowerCase())
  );
}

/** What a repo the token can't reach answers: GitHub's 404 says nothing about whether it exists. */
export function cantAccess(repo) {
  return `You can't access ${repo}: the reviewer can't see it, or the GitHub App isn't installed on it. Say so; don't guess what it holds.`;
}

const granted = (repo, reachable) => (inGrant(repo, reachable) ? null : cantAccess(repo));

/** Why a git call is refused, or null: its arguments, and with `repo` a clone this question's grant reaches. */
export function gitRefusal(args, repo, reachable) {
  return vetGit(args) ?? (repo === undefined ? null : (vetRepo(repo) ?? granted(repo, reachable)));
}

/** Why a clone is refused, or null. */
export function cloneRefusal(repo, ref, reachable) {
  return vetRepo(repo) ?? vetRef(ref) ?? granted(repo, reachable);
}

const DENY = (reason) => ({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: reason,
  },
});

/**
 * Tools that hand a draft or a request to the Worker: they reach nothing, and post nothing. `linear_issue` and
 * `linear_search` ask the Worker to read Linear, which it does with fixed queries: the container has no Linear key.
 */
const HANDED_ON = ["draft_review", "github_act", "linear_act", "linear_issue", "linear_search"].map(
  (one) => `mcp__${SERVER}__${one}`,
);

/** Whether a path under `clones` is in a repo of `reachable`, matched without case as GitHub names repos. */
function cloneInGrant(clones, target, reachable, realpath) {
  const [owner, name] = relative(
    realpath(clones),
    realpath(isAbsolute(target) ? target : resolve(clones, target)),
  ).split(/[\\/]/);
  return Boolean(owner && name) && inGrant(`${owner}/${name}`, reachable);
}

/**
 * The PreToolUse gate. Read, Grep and Glob stay in `cwd` (the PR's checkout) or `clones`; git, clone_repo and
 * github_api pass their vetting. With `reachable` (hosted: the repos this question's token names), only those clones
 * can be read or made: one cloned while the person could see it is shut once they can't. Anything else is denied.
 * `realpath` follows symlinks, so a link out of a root is judged where it points.
 */
export function readOnlyHooks(cwd, clones, reachable, realpath) {
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
            const escapes = [name === "Glob" ? pattern : null, glob]
              .filter((value) => typeof value === "string")
              .some(outsidePath);
            const inRoot =
              roots.some((root) => isInside(root, target, realpath)) ||
              (reachable !== null &&
                isInside(clones, target, realpath) &&
                cloneInGrant(clones, target, reachable, realpath));
            return inRoot && !escapes
              ? {}
              : DENY("Only the checkout and the repos you cloned can be read.");
          }
          // The web, open by Jai's choice (2026-11-13: "we need feature richness"): WebFetch can put what the agent read in a
          // URL it fetches, so a prompt in a PR could send code out. The tokens can't go: no tool reads them.
          if (WEB_TOOLS.includes(name) || HANDED_ON.includes(name)) {
            return {};
          }
          const reason =
            name === `mcp__${SERVER}__git`
              ? gitRefusal(given.args, given.repo, reachable)
              : name === `mcp__${SERVER}__clone_repo`
                ? cloneRefusal(given.repo, given.ref, reachable)
                : name === `mcp__${SERVER}__github_api`
                  ? vetApiPath(given.path)
                  : "Only reading is allowed.";
          return reason === null ? {} : DENY(reason);
        },
      ],
    },
  ];
}

/** The tools' names, for `allowedTools`. */
export function readToolNames(hasToken, readsLinear = false) {
  return [
    "git",
    ...(hasToken ? ["clone_repo", "github_api"] : []),
    "draft_review",
    "github_act",
    "linear_act",
    ...(readsLinear ? ["linear_issue", "linear_search"] : []),
  ].map((name) => `mcp__${SERVER}__${name}`);
}
