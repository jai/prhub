import { parse } from "yaml";

/**
 * Whether the people a repo's `.policy.yml` names have approved, apart from its conditions (checks, signatures,
 * workflows). PolicyBot answers one word for both, so a PR blocked by a size gate read as unreviewed; Jai's "approved"
 * means people only, and checks have their own mark. Rules follow PolicyBot's: a rule whose `if` does not match is
 * skipped, and a policy whose every rule is skipped passes.
 */

export type PeopleDecision = "APPROVED" | "REVIEW_REQUIRED" | "CHANGES_REQUESTED";

export interface PeopleFacts {
  base: string;
  title: string;
  author: string;
  files: string[];
  /** Everyone who authored or committed a commit on the PR. */
  committers: string[];
  /** When the head commit was made: approvals before it don't count where a rule says so. */
  headAt: string | null;
  labels: string[];
  /** Each person's latest review, as GitHub keeps it. */
  reviews: { login: string; state: string; submittedAt: string | null }[];
  comments: { login: string; body: string; createdAt: string }[];
}

/** What a PR query asks for so `.policy.yml`'s people can be counted (policy-people.ts). */
export const PEOPLE_FIELDS = `baseRefName title author { login }
  files(first: 100) { nodes { path } }
  labels(first: 20) { nodes { name } }
  latestReviews(first: 50) { nodes { author { login } state submittedAt } }
  peopleReviews: reviews(last: 100) { nodes { author { login } state submittedAt } }
  peopleComments: comments(last: 100) { nodes { author { login } body createdAt } }
  committers: commits(last: 100) { nodes { commit { committedDate
    author { user { login } } committer { user { login } } } } }`;

export interface PeopleNode {
  baseRefName: string;
  title: string;
  author: { login: string } | null;
  files?: { nodes: { path: string }[] } | null;
  labels?: { nodes: { name: string }[] };
  latestReviews: { nodes: { author: { login: string } | null; state: string; submittedAt: string | null }[] };
  /** Every review: `latestReviews` leaves out the reader's own, and the Worker reads as Jai. */
  peopleReviews?: { nodes: { author: { login: string } | null; state: string; submittedAt: string | null }[] };
  peopleComments?: { nodes: { author: { login: string } | null; body: string; createdAt: string }[] };
  committers?: { nodes: { commit: { committedDate: string; author: { user: { login: string } | null } | null;
    committer: { user: { login: string } | null } | null } }[] };
}

export function factsOf(node: PeopleNode): PeopleFacts {
  const commits = node.committers?.nodes ?? [];
  const logins = (list: (string | undefined)[]) => [...new Set(list.filter((login): login is string => !!login))];
  return {
    base: node.baseRefName,
    title: node.title,
    author: node.author?.login ?? "",
    files: (node.files?.nodes ?? []).map((file) => file.path),
    committers: logins(commits.flatMap(({ commit }) => [commit.author?.user?.login, commit.committer?.user?.login])),
    headAt: commits.at(-1)?.commit.committedDate ?? null,
    labels: (node.labels?.nodes ?? []).map((label) => label.name),
    reviews: latestByPerson([...node.latestReviews.nodes, ...node.peopleReviews?.nodes ?? []]),
    comments: (node.peopleComments?.nodes ?? []).flatMap((comment) => comment.author
      ? [{ login: comment.author.login, body: comment.body, createdAt: comment.createdAt }] : []),
  };
}

/** Each person's latest review that took a side: a comment-only review changes nothing, a dismissal undoes one. */
function latestByPerson(
  reviews: { author: { login: string } | null; state: string; submittedAt: string | null }[],
): PeopleFacts["reviews"] {
  const latest = new Map<string, PeopleFacts["reviews"][number]>();
  for (const review of reviews) {
    if (!review.author || !["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].includes(review.state)) continue;
    const seen = latest.get(review.author.login);
    if (!seen || (review.submittedAt ?? "") > (seen.submittedAt ?? "")) {
      latest.set(review.author.login, { login: review.author.login, state: review.state, submittedAt: review.submittedAt });
    }
  }
  return [...latest.values()];
}

/** Whether `login` is in the team (`org/slug`) or the org. Answers null when it can't tell. */
export interface Membership {
  inTeam(team: string, login: string): Promise<boolean | null>;
  inOrg(org: string, login: string): Promise<boolean | null>;
}

interface Actors { users?: string[]; teams?: string[]; organizations?: string[] }
interface Rule {
  name: string;
  if?: Record<string, unknown>;
  options?: {
    allow_author?: boolean; allow_contributor?: boolean; allow_non_author_contributor?: boolean;
    invalidate_on_push?: boolean;
    methods?: { comments?: string[]; comment_patterns?: string[]; github_review?: boolean };
  };
  requires?: Actors & { count?: number };
}
type Expression = string | { and?: Expression[]; or?: Expression[] };
interface Policy {
  policy?: { approval?: Expression[]; disapproval?: { requires?: Actors } };
  approval_rules?: Rule[];
}

const DEFAULT_COMMENTS = [":+1:", "👍"];

/** The parsed file, or null when it isn't a policy this can read. */
export function parsePolicy(text: string): Policy | null {
  try {
    const policy = parse(text, { maxAliasCount: 100 }) as Policy | null;
    return policy && Array.isArray(policy.policy?.approval) ? policy : null;
  } catch {
    return null;
  }
}

export async function peopleDecision(policy: Policy, pr: PeopleFacts, members: Membership): Promise<PeopleDecision | null> {
  const rules = new Map((policy.approval_rules ?? []).map((rule) => [rule.name, rule]));
  const counts = async (who: Actors, login: string) => await isActor(who, login, members);
  const disapprovers = policy.policy?.disapproval?.requires;
  if (disapprovers) {
    for (const review of pr.reviews) {
      if (review.state === "CHANGES_REQUESTED" && await counts(disapprovers, review.login) === true) {
        return "CHANGES_REQUESTED";
      }
    }
  }
  const result = await all(policy.policy?.approval ?? [], "and", rules, pr, members);
  // PolicyBot calls a policy whose every rule was skipped an error: nobody has approved it.
  return result === null ? null : result === "approved" ? "APPROVED" : "REVIEW_REQUIRED";
}

/** "approved", "pending", "skipped", or null when a rule is missing or membership couldn't be read. */
type Outcome = "approved" | "pending" | "skipped";

async function all(
  items: Expression[], join: "and" | "or", rules: Map<string, Rule>, pr: PeopleFacts, members: Membership,
): Promise<Outcome | null> {
  const outcomes: Outcome[] = [];
  for (const item of items) {
    const outcome = await evaluate(item, rules, pr, members);
    if (outcome === null) return null;
    outcomes.push(outcome);
  }
  const counted = outcomes.filter((outcome) => outcome !== "skipped");
  if (counted.length === 0) return "skipped";
  const approved = join === "and" ? counted.every((o) => o === "approved") : counted.some((o) => o === "approved");
  return approved ? "approved" : "pending";
}

async function evaluate(item: Expression, rules: Map<string, Rule>, pr: PeopleFacts, members: Membership): Promise<Outcome | null> {
  if (typeof item === "string") {
    const rule = rules.get(item);
    return rule ? await ruleOutcome(rule, pr, members) : null;
  }
  if (item.and) return await all(item.and, "and", rules, pr, members);
  if (item.or) return await all(item.or, "or", rules, pr, members);
  return null;
}

async function ruleOutcome(rule: Rule, pr: PeopleFacts, members: Membership): Promise<Outcome | null> {
  const applies = await matches(rule.if ?? {}, pr, members);
  if (applies === null) return null;
  if (!applies) return "skipped";
  const needed = rule.requires?.count ?? 0;
  if (needed <= 0) return "approved";
  const options = rule.options ?? {};
  const contributors = new Set(pr.committers.filter((login) => login !== pr.author));
  const eligible = async (login: string): Promise<boolean | null> => {
    if (login === pr.author && !options.allow_author) return false;
    if (contributors.has(login) && !options.allow_contributor && !options.allow_non_author_contributor) return false;
    return await isActor(rule.requires ?? {}, login, members);
  };
  const after = options.invalidate_on_push && pr.headAt ? pr.headAt : "";
  const approvers = new Set<string>();
  if (options.methods?.github_review !== false) {
    for (const review of pr.reviews) {
      if (review.state === "APPROVED" && (review.submittedAt ?? "") >= after) approvers.add(review.login);
    }
  }
  const phrases = options.methods?.comments ?? (options.methods ? [] : DEFAULT_COMMENTS);
  const patterns = (options.methods?.comment_patterns ?? []).flatMap((source) => safeRegExp(source) ?? []);
  for (const comment of pr.comments) {
    const said = phrases.some((phrase) => comment.body.includes(phrase)) || patterns.some((p) => p.test(comment.body));
    if (said && comment.createdAt >= after) approvers.add(comment.login);
  }
  let approved = 0;
  for (const login of approvers) {
    const ok = await eligible(login);
    if (ok === null) return null;
    if (ok) approved += 1;
  }
  return approved >= needed ? "approved" : "pending";
}

/** Whether a rule's `if` holds; true for predicates this doesn't know, so an unknown one never hides a rule. */
async function matches(predicates: Record<string, unknown>, pr: PeopleFacts, members: Membership): Promise<boolean | null> {
  for (const [name, value] of Object.entries(predicates)) {
    const predicate = (value ?? {}) as Record<string, unknown>;
    const strings = (key: string) => (Array.isArray(predicate[key]) ? predicate[key] as string[] : []);
    switch (name) {
      case "targets_branch":
        if (!test(predicate.pattern, pr.base)) return false;
        break;
      case "title":
        if (strings("matches").length && !strings("matches").some((p) => test(p, pr.title))) return false;
        if (strings("not_matches").some((p) => test(p, pr.title))) return false;
        break;
      case "changed_files": {
        const ignored = (file: string) => strings("ignore").some((p) => test(p, file));
        const files = pr.files.filter((file) => !ignored(file));
        if (!files.some((file) => strings("paths").some((p) => test(p, file)))) return false;
        break;
      }
      case "only_changed_files":
        if (!pr.files.every((file) => strings("paths").some((p) => test(p, file)))) return false;
        break;
      case "has_labels":
        if (!(Array.isArray(value) ? value as string[] : []).every((label) => pr.labels.includes(label))) return false;
        break;
      case "has_author_in": {
        const isIn = await isActor(predicate as Actors, pr.author, members);
        if (isIn === null) return null;
        if (!isIn) return false;
        break;
      }
      default:
        break;
    }
  }
  return true;
}

async function isActor(who: Actors, login: string, members: Membership): Promise<boolean | null> {
  if ((who.users ?? []).includes(login)) return true;
  let unknown = false;
  for (const team of who.teams ?? []) {
    const inTeam = await members.inTeam(team, login);
    if (inTeam) return true;
    if (inTeam === null) unknown = true;
  }
  for (const org of who.organizations ?? []) {
    const inOrg = await members.inOrg(org, login);
    if (inOrg) return true;
    if (inOrg === null) unknown = true;
  }
  return unknown ? null : false;
}

function test(pattern: unknown, text: string): boolean {
  return typeof pattern === "string" && (safeRegExp(pattern)?.test(text) ?? false);
}

function safeRegExp(source: string): RegExp | null {
  try {
    return new RegExp(source);
  } catch {
    return null;
  }
}
