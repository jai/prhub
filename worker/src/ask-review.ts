// PRHub's own review of a PR, as Ask's agent reads it (docs/api.md, "AI on a subscription"): the risk, what the PR does,
// the bugs found, whether it meets its ticket, whether its description reads as AI slop, and the key lines, each with
// its file, line and the line's own text. It is what the PR's page shows, made by a model (`ai.ts`), so the agent is
// told it is automated and may be wrong. `storedReview` reads R2; nothing else here calls anything.
import type { KeyLines } from "./ai.ts";
import { aiStoreKey } from "./ai-run.ts";
import { aiConfigOf } from "./config.ts";
import { type Env, scopedKey } from "./env.ts";
import type { RepoFullName, Sha } from "./ids.ts";
import { DEFAULT_CONTEXT } from "./key-lines.ts";
import { parseDiff, type Side } from "./key-lines.ts";

/** The most characters the review takes in the agent's instructions. */
export const REVIEW_KEPT = 6_000;
/** The most of one note, and of one line of code. */
const NOTE_KEPT = 300;
const CODE_KEPT = 200;

const short = (text: string, most: number) =>
  text.length > most ? `${text.slice(0, most)}…` : text;

/** Each line the diff shows, by `path:side:line`, as written, without its `+`, `-` or space. */
export function diffLines(diff: string): Map<string, string> {
  const lines = new Map<string, string>();
  for (const file of parseDiff(diff)) {
    for (const marked of file.marked) {
      const [, side, line, code] = /^([RL])(\d+)[+\- ](.*)$/.exec(marked) ?? [];
      if (side) {
        lines.set(`${file.path}:${side === "R" ? "RIGHT" : "LEFT"}:${line}`, code);
      }
    }
  }
  return lines;
}

interface Noted {
  path: string;
  line: number;
  side: Side;
  why: string;
}

function noted(
  { path, line, side, why }: Noted,
  lines: Map<string, string> | null,
  label = "",
): string {
  const where = `${path}:${line}${side === "LEFT" ? " (old side)" : ""}`;
  const code = lines?.get(`${path}:${side}:${line}`)?.trim();
  return `- ${label}${where}: ${short(why.trim(), NOTE_KEPT)}${code ? `\n  > ${short(code, CODE_KEPT)}` : ""}`;
}

function render(review: KeyLines, lines: Map<string, string> | null, keyLines: number): string {
  const { summary } = review;
  const out = [`Risk: ${summary.risk}. ${short(summary.riskWhy, NOTE_KEPT)}`];
  out.push(
    summary.bugs.length > 0 ? `Bugs found (${summary.bugs.length}):` : "Bugs found: none.",
    ...summary.bugs.map((bug) => noted(bug, lines)),
  );
  const requirements = summary.requirements;
  if (requirements?.state === "mismatch") {
    out.push(
      `Requirements: scope mismatch with ${requirements.tickets.join(", ")}.`,
      ...requirements.gaps.map((gap) => `- ${short(gap, NOTE_KEPT)}`),
    );
  } else if (requirements?.state === "fits") {
    out.push(`Requirements: fits ${requirements.tickets.join(", ")}.`);
  } else if (requirements?.state === "multiple") {
    out.push(
      `Requirements: not checked, the PR names several tickets (${requirements.tickets.join(", ")}).`,
    );
  } else {
    out.push("Requirements: not checked, no ticket was read.");
  }
  out.push(
    summary.slop.isSlop ? "Reads as AI slop: yes." : "Reads as AI slop: no.",
    ...summary.slop.tells.map((tell) => `- ${short(tell, NOTE_KEPT)}`),
  );
  if (summary.points.length > 0) {
    out.push("What this does:", ...summary.points.map((point) => `- ${short(point, NOTE_KEPT)}`));
  }
  const items = review.items.slice(0, keyLines);
  if (items.length > 0) {
    out.push(
      `Key lines (${items.length}${items.length < review.items.length ? ` of ${review.items.length}` : ""}):`,
      ...items.map((item) => noted(item, lines, `[${item.kind}] `)),
    );
  }
  if (review.leftOut.length > 0) {
    out.push(`The review did not read ${review.leftOut.length} files that were too big for it.`);
  }
  return out.join("\n");
}

/**
 * The review within `REVIEW_KEPT` characters. Too long, it loses first each line's code, then its key lines from the
 * last, then its end: the risk, the bugs and the requirements, which come first, go last.
 */
export function reviewText(review: KeyLines, diff: string): string {
  const lines = diffLines(diff);
  const whole = render(review, lines, review.items.length);
  if (whole.length <= REVIEW_KEPT) {
    return whole;
  }
  for (let kept = review.items.length; kept >= 0; kept--) {
    const text = render(review, null, kept);
    if (text.length <= REVIEW_KEPT) {
      return `${text}\n[cut: the lines' code${kept < review.items.length ? " and some key lines" : ""} left out]`;
    }
  }
  return `${render(review, null, 0).slice(0, REVIEW_KEPT)}\n[cut]`;
}

/** A stored key lines answer that is a review, not a failure or anything else. */
export function isReview(value: unknown): value is KeyLines {
  const { items, summary, leftOut } = (value ?? {}) as Partial<KeyLines>;
  return (
    Array.isArray(items) &&
    Array.isArray(leftOut) &&
    typeof summary === "object" &&
    summary !== null &&
    typeof summary.risk === "string" &&
    typeof summary.riskWhy === "string" &&
    Array.isArray(summary.points) &&
    Array.isArray(summary.bugs) &&
    typeof summary.slop === "object" &&
    summary.slop !== null &&
    Array.isArray(summary.slop.tells)
  );
}

/**
 * The review the PR's page shows at `head`: the one made at the default context and model, else the newest other one
 * kept for this head (the person picked another model). Null when none is made yet, or the last try failed.
 */
export async function storedReview(
  repo: RepoFullName,
  number: number,
  head: Sha,
  env: Env,
): Promise<KeyLines | null> {
  const read = async (key: string) => {
    const value = await (await env.DIFFS.get(key))?.json<unknown>().catch(() => null);
    return isReview(value) ? value : null;
  };
  const usual = await read(
    aiStoreKey(
      {
        kind: "key_lines",
        repo,
        number,
        head,
        context: DEFAULT_CONTEXT,
        choice: aiConfigOf(env).defaults.key_lines,
      },
      env,
    ),
  );
  if (usual) {
    return usual;
  }
  const others = await env.DIFFS.list({
    prefix: scopedKey(env, `ai/${repo}/${number}/${head}/key-lines-v5-`),
    limit: 20,
  });
  const newestFirst = [...others.objects].sort(
    (a, b) => b.uploaded.getTime() - a.uploaded.getTime(),
  );
  for (const { key } of newestFirst) {
    const review = await read(key);
    if (review) {
      return review;
    }
  }
  return null;
}
