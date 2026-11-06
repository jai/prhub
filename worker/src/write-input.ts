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

function parseComment(input: unknown): ReviewComment | null {
  const { path, line, side, body } = (input ?? {}) as Partial<Record<string, unknown>>;
  const isValid = typeof path === "string" && path !== "" && typeof line === "number" && typeof body === "string"
    && body !== "" && (side === "LEFT" || side === "RIGHT");
  return isValid ? { path, line, side, body } : null;
}

export function parseWrite(input: unknown): Write | null {
  const value = input as Partial<Record<string, unknown>> | null;
  const text = (key: string) => (typeof value?.[key] === "string" ? value[key] as string : "");
  const body = text("body");
  switch (value?.kind) {
    case "comment":
      return body ? { kind: "comment", body } : null;
    case "review": {
      const event = text("event");
      const list = Array.isArray(value.comments) ? value.comments : [];
      const comments = list.map(parseComment).filter((comment) => comment !== null);
      if (comments.length !== list.length || !text("commit") || !["APPROVE", "REQUEST_CHANGES", "COMMENT"].includes(event)
        || (event !== "APPROVE" && !body && comments.length === 0)) {
        return null;
      }
      return { kind: "review", event: event as "APPROVE", body, commit: text("commit"), comments };
    }
    case "resolve":
      return text("thread") && typeof value.resolved === "boolean"
        ? { kind: "resolve", thread: text("thread"), resolved: value.resolved } : null;
    case "line": {
      const side = text("side");
      const line = value.line;
      if (!body || !text("commit") || !text("path") || typeof line !== "number" || (side !== "LEFT" && side !== "RIGHT")) {
        return null;
      }
      return { kind: "line", body, commit: text("commit"), path: text("path"), line, side };
    }
    case "reply":
      return body && text("thread") ? { kind: "reply", body, thread: text("thread") } : null;
    case "update_branch":
      return text("commit") ? { kind: "update_branch", commit: text("commit") } : null;
    case "remove_request":
      return { kind: "remove_request" };
    case "checkbox":
      return Number.isInteger(value.index) && typeof value.checked === "boolean"
        ? { kind: "checkbox", index: value.index as number, checked: value.checked,
          task: typeof value.task === "string" ? value.task : null } : null;
    case "edit_body":
      return typeof value.body === "string"
        ? { kind: "edit_body", body, base: typeof value.base === "string" ? value.base : null } : null;
    case "merge": {
      const method = text("method");
      return text("commit") && (method === "merge" || method === "squash" || method === "rebase")
        ? { kind: "merge", method, commit: text("commit") } : null;
    }
    case "viewed":
      return text("pullRequest") && text("path") && typeof value.viewed === "boolean"
        ? { kind: "viewed", pullRequest: text("pullRequest"), path: text("path"), viewed: value.viewed } : null;
    default:
      return null;
  }
}
