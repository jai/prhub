/** What Jai asks about a PR and what comes back, as the phone shows it. Nothing here calls anything. */

export interface AskAnchor {
  path: string;
  line: number;
  side: "LEFT" | "RIGHT";
  code?: string;
}

export interface AskInput {
  question: string;
  head: string;
  anchor: AskAnchor | null;
}

export interface AskMessage {
  id: string;
  role: "you" | "agent";
  text: string;
  /** `path:line`, on a question about one line. */
  anchor: string | null;
}

export interface AskChat {
  messages: AskMessage[];
  isWorking: boolean;
  /** What the agent is doing right now, in a few words. */
  activity: string | null;
  /** Why it stopped short of an answer. */
  problem: string | null;
  costCents: number | null;
}

const QUESTION = "\n\nQuestion: ";
const ANCHOR = /^Asked about (.+):(\d+) on the (?:new|old) side/m;
const MAX_QUESTION = 4_000;

export function parseAskInput(body: unknown): AskInput | null {
  const { question, head, anchor } = (body ?? {}) as Partial<AskInput>;
  if (typeof question !== "string" || !question.trim() || question.length > MAX_QUESTION
    || typeof head !== "string" || !/^[0-9a-f]{40}$/.test(head)) {
    return null;
  }
  const isAnchor = anchor && typeof anchor.path === "string" && Number.isInteger(anchor.line)
    && (anchor.side === "LEFT" || anchor.side === "RIGHT");
  return { question: question.trim(), head, anchor: isAnchor ? anchor : null };
}

/** `movedFrom`: the head of the last question. The checkout stays where it was until the agent moves it. */
export function askPrompt({ question, head, anchor }: AskInput, movedFrom: string | null): string {
  const context = [`The PR's head is ${head}.`];
  if (movedFrom && movedFrom !== head) {
    context.push(`It has moved since the last question: run git fetch origin ${head} && git checkout ${head} first.`);
  }
  if (anchor) {
    const code = anchor.code ? `: ${anchor.code}` : "";
    context.push(`Asked about ${anchor.path}:${anchor.line} on the ${anchor.side === "LEFT" ? "old" : "new"} side${code}`);
  }
  return `${context.join("\n")}${QUESTION}${question}`;
}

interface SessionEvent {
  id: string;
  type: string;
  content?: { type: string; text?: string }[];
  name?: string;
  input?: { file_path?: string; path?: string; pattern?: string };
  stop_reason?: { type: string };
  error?: { message?: string };
}

function textOf(event: SessionEvent): string {
  return (event.content ?? []).flatMap((block) => (block.type === "text" && block.text ? [block.text] : [])).join("\n");
}

function activityOf(event: SessionEvent): string {
  const target = event.input?.file_path ?? event.input?.path ?? event.input?.pattern;
  return event.name === "bash" || !target ? "Reading the repo" : `Reading ${target.split("/").pop()}`;
}

const STOPS: Record<string, string> = {
  budget_reached: "This chat reached its spending limit.",
  retries_exhausted: "The agent stopped after repeated errors.",
};

/** Working from the question until the session goes idle: right after a send it can still read idle from before. */
export function chatOf(events: SessionEvent[], costCents: number | null, marker = QUESTION): AskChat {
  const messages: AskMessage[] = [];
  let isWorking = false;
  let activity: string | null = null;
  let problem: string | null = null;
  for (const event of events) {
    if (event.type === "user.message") {
      const text = textOf(event);
      const split = text.indexOf(marker);
      const anchor = ANCHOR.exec(text);
      messages.push({
        id: event.id, role: "you", text: split < 0 ? text : text.slice(split + marker.length),
        anchor: anchor ? `${anchor[1]}:${anchor[2]}` : null,
      });
      isWorking = true;
      activity = null;
      problem = null;
    } else if (event.type === "agent.message") {
      messages.push({ id: event.id, role: "agent", text: textOf(event), anchor: null });
    } else if (event.type === "agent.tool_use") {
      activity = activityOf(event);
    } else if (event.type === "session.error") {
      problem = event.error?.message ?? "The agent hit an error.";
    } else if (event.type === "session.status_idle" && event.stop_reason?.type !== "requires_action") {
      isWorking = false;
      activity = null;
      problem = STOPS[event.stop_reason?.type ?? ""] ?? null;
    } else if (event.type === "session.status_terminated") {
      isWorking = false;
      activity = null;
      problem = "This chat has ended. The next question starts a new one.";
    }
  }
  return { messages, isWorking, activity, problem, costCents };
}
