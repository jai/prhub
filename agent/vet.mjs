// What the agent may ask for, checked without touching anything: the tools' input shapes, git arguments, repo names,
// refs and GitHub API paths, and the options and environment every git call runs with. Each check returns why it
// refuses, or null.
import { isAbsolute } from "node:path";
import { z } from "zod";

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
  flags:
    words(`-p --patch --no-patch -s --stat --shortstat --numstat --name-only --name-status --summary --raw -w -b
    --ignore-all-space --ignore-space-change --no-renames -M -R --patience --histogram --minimal --no-color --word-diff
    --full-index --binary --abbrev`),
  attached: words("-U --unified --diff-filter --stat-width --abbrev"),
  separate: words("--diff-filter"),
};

/** A history. `-S` and `-G` search it for a string, and `-L` names a range of a file in the repo's history. */
const LOG = {
  flags: [
    ...DIFF.flags,
    ...words(`--oneline --graph --decorate --no-decorate --all --branches --tags --remotes --merges
    --no-merges --first-parent --reverse --date-order --topo-order --author-date-order --abbrev-commit
    --no-abbrev-commit --full-history --simplify-merges --ancestry-path --left-right --cherry-pick --cherry-mark
    --boundary --follow -i --regexp-ignore-case --all-match --invert-grep -E --extended-regexp -F --fixed-strings -m
    --cc --full-diff --source --use-mailmap --parents --children --no-walk --count --notes --no-notes --pretty`),
  ],
  attached: [
    ...DIFF.attached,
    ...words(`-n --max-count --skip --since --until --after --before --author --committer
    --grep -S -G -L --format --pretty --date --min-parents --max-parents --decorate-refs`),
  ],
  separate: [
    ...DIFF.separate,
    ...words(`-n --max-count --skip --since --until --after --before --author --committer
    --grep -S -G -L --date --min-parents --max-parents`),
  ],
  counts: true,
};

const none = { flags: [], attached: [], separate: [] };

/**
 * Git subcommands that only read, each with the only options it takes. An option not listed is refused, and so is
 * every abbreviation: `--ignore-revs-f` is not `--ignore-revs-file`, it is unknown.
 */
export const GIT_READS = new Map(
  Object.entries({
    log: LOG,
    show: LOG,
    "rev-list": LOG,
    shortlog: {
      flags: words("-s --summary -n --numbered -e --email --all --merges --no-merges"),
      attached: words("--since --until --after --before --author --max-count --format"),
      separate: words("--since --until --after --before --author --max-count"),
      counts: true,
    },
    diff: { ...DIFF, flags: [...DIFF.flags, "--cached", "--staged", "--merge-base"] },
    grep: {
      flags:
        words(`-n --line-number -i --ignore-case -w --word-regexp -v --invert-match -l --files-with-matches
    -L --files-without-match --count -h -H --full-name -E --extended-regexp -F --fixed-strings -G --basic-regexp
    -P --perl-regexp -I --heading --break --cached --all-match --and --or --not --only-matching --column -p
    --show-function -W --function-context -a --text`),
      attached: words(
        "-e -A -B -C --context --after-context --before-context --max-depth -m --max-count",
      ),
      separate: words(
        "-e -A -B -C --context --after-context --before-context --max-depth -m --max-count",
      ),
    },
    blame: {
      flags: words(
        "-l -s -e --show-email -w -M -C --porcelain --line-porcelain -t --root --show-name --show-number -f -n",
      ),
      attached: words("-L"),
      separate: words("-L"),
    },
    describe: {
      flags: words("--tags --all --always --long --contains --exact-match --first-parent --abbrev"),
      attached: words("--abbrev --match --exclude --candidates"),
      separate: words("--match --exclude --candidates"),
    },
    "rev-parse": {
      ...none,
      flags: words(
        "--short --abbrev-ref --verify -q --quiet --symbolic-full-name --is-shallow-repository",
      ),
    },
    "merge-base": { ...none, flags: words("--is-ancestor --all --octopus --independent") },
    "name-rev": { ...none, flags: words("--tags --name-only --always") },
    "ls-files": {
      ...none,
      flags: words("--cached --stage -s --full-name --error-unmatch --deleted --modified"),
    },
    "ls-tree": {
      flags: words("-r -t -d --name-only --name-status -l --long --full-name --full-tree --abbrev"),
      attached: words("--abbrev"),
      separate: [],
    },
    "cat-file": { ...none, flags: words("-t -s -p -e") },
    "for-each-ref": {
      flags: [],
      attached: words(
        "--contains --no-contains --merged --no-merged --points-at --sort --format --count",
      ),
      separate: words(
        "--contains --no-contains --merged --no-merged --points-at --sort --format --count",
      ),
    },
  }),
);

/**
 * Writers and runners, refused wherever they appear, whatever the lists above say: a last guard if a list is ever
 * wrong. `-c` and `-o` here also take every option that starts with them, so grep counts with `--count`.
 */
const NEVER =
  /^(?:--output|-o|--ext-diff|--textconv|--open-files-in-pager|-O|--exec|--upload-pack|--config|-c|--git-dir|--work-tree|--namespace)/;

/** A path argument as given: none absolute, from home, or climbing. */
export function outsidePath(arg) {
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

/** `owner/name` as GitHub spells them, and nothing that climbs a directory. */
const REPO = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9_.-]{1,100}$/;

export function vetRepo(repo) {
  return typeof repo === "string" &&
    REPO.test(repo) &&
    !repo.split("/").some((part) => part === "." || part === "..")
    ? null
    : "Name a repo as owner/name.";
}

/** A branch, tag or commit: no option, no climbing, no spaces. */
export function vetRef(ref) {
  return ref === undefined ||
    (typeof ref === "string" && /^[A-Za-z0-9_][\w./-]{0,199}$/.test(ref) && !ref.includes(".."))
    ? null
    : "Name a branch, tag or commit.";
}

export const API = "https://api.github.com";

/** Why an API path is refused, or null for a path on GitHub's REST API. Only GET is ever sent. */
export function vetApiPath(path) {
  if (
    typeof path !== "string" ||
    !path.startsWith("/") ||
    path.startsWith("//") ||
    path.length > 1_000 ||
    /[\s\\@#]/.test(path) ||
    path.split("?")[0].split("/").includes("..")
  ) {
    return "Give a path on GitHub's REST API, such as /repos/owner/name/pulls/1/reviews.";
  }
  return new URL(path, API).origin === API ? null : "Only api.github.com can be read.";
}

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

/** A vetted read as git runs it: the subcommand, then the options that turn the repo's programs off, then the rest. */
export function gitCommand(args) {
  const [command, ...rest] = args;
  return [command, ...(NO_PROGRAMS[command] ?? []), ...rest];
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

/** Git's whole argument list in `dir`: the safe settings and the token's header come before anything asked for. */
export function gitArgv(dir, args, token) {
  return ["-C", dir, ...SAFE_GIT, ...authArgs(token), ...args];
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

/**
 * Where a clone checks out `ref`: a full commit is fetched by itself first (a branch fetch may not hold it), then tried
 * as `origin/<ref>` and as written; no ref is the default branch.
 */
export function checkoutTargets(ref) {
  return {
    fetch: ref && /^[0-9a-f]{40}$/.test(ref) ? ref : null,
    targets: ref === undefined ? ["origin/HEAD"] : [`origin/${ref}`, ref],
  };
}

/** The most line comments one draft holds: a review past this is a wall, not a review. */
export const DRAFT_COMMENTS = 30;

/** Each tool's input, as the SDK checks it before the tool runs. */
export const INPUTS = {
  git: {
    args: z
      .array(z.string())
      .min(1)
      .describe('The subcommand and its arguments, such as ["log", "--oneline", "-20"]'),
    repo: z.string().optional(),
  },
  clone_repo: { repo: z.string().describe("owner/name"), ref: z.string().optional() },
  github_api: {
    path: z.string().describe("Such as /repos/owner/name/pulls/1/reviews?per_page=100"),
  },
  draft_review: {
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
  github_act: { action: z.record(z.string(), z.unknown()).describe("One action, as above") },
  linear_issue: {
    key: z
      .string()
      .regex(/^[A-Za-z][A-Za-z0-9]{0,9}-\d+$/)
      .describe("The ticket's key, such as ENG-12"),
    comments: z.boolean().optional().describe("true to read the ticket's comments too"),
  },
  linear_search: {
    text: z.string().min(1).max(200).describe("A ticket's key, or words to look for"),
  },
  linear_act: {
    issue: z
      .string()
      .regex(/^[A-Za-z][A-Za-z0-9]{0,9}-\d+$/)
      .describe("The ticket's key, such as ENG-12"),
    body: z.string().min(1).max(10_000).describe("The comment, in Markdown, with @Name mentions"),
  },
};
