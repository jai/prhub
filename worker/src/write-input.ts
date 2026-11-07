/** What the phone can say on a PR, as Jai: the Worker's token is his. */
export type Write =
  | { kind: "comment"; body: string }
  | { kind: "review"; event: "APPROVE" | "REQUEST_CHANGES" | "COMMENT"; body: string; commit: string;
    comments: ReviewComment[] }
  | { kind: "resolve"; thread: string; resolved: boolean }
  | { kind: "line"; body: string; commit: string; path: string; line: number; side: "LEFT" | "RIGHT" }
  | { kind: "reply"; body: string; thread: string }
  | { kind: "viewed"; pullRequest: string; path: string; viewed: boolean }
  | { kind: "update_branch"; commit: string }
  | { kind: "remove_request" }
  | { kind: "checkbox"; index: number; checked: boolean; task: string | null }
  | { kind: "edit_body"; body: string; base: string | null }
  | { kind: "merge"; method: "merge" | "squash" | "rebase"; commit: string };

const TASK = /^(\s*[-*] \[)[ xX](\] )/;

/**
 * The body with its task at `index` set, or null if it has no such task. Tasks are counted as the phone draws them, so
 * one inside an HTML comment or a code fence doesn't count.
 */
export function toggleTask(body: string, index: number, checked: boolean, task: string | null = null): string | null {
  const lines = body.split("\n");
  let seen = 0;
  let inFence = false;
  let inComment = false;
  for (const [number, line] of lines.entries()) {
    if (inComment) {
      inComment = !line.includes("-->");
    } else if (line.includes("<!--")) {
      inComment = !line.slice(line.indexOf("<!--")).includes("-->");
    } else if (/^\s*```/.test(line)) {
      inFence = !inFence;
    } else if (!inFence && TASK.test(line)) {
      if (seen === index) {
        // A late copy of a tap must not tick whatever task has since moved into this place.
        if (task !== null && line.replace(TASK, "").trim() !== task.trim()) {
          return null;
        }
        lines[number] = line.replace(TASK, `$1${checked ? "x" : " "}$2`);
        return lines.join("\n");
      }
      seen += 1;
    }
  }
  return null;
}

export interface ReviewComment {
  path: string;
  line: number;
  side: "LEFT" | "RIGHT";
  body: string;
}

export { parseWrite } from "./boundary.ts";
