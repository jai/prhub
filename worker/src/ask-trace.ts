// What happened to an Ask turn (docs/api.md, "Tracing an Ask"): one id per turn, the question's own, and one
// `ask_event` log line at each stage, so `scripts/ask-trace.sh <id>` reads the turn back from Workers Logs in one step.

/** Where a turn failed: the phone's request, this Worker, GitHub, the Agent SDK container, or the model behind it. */
export type AskSide = "app" | "worker" | "github" | "container" | "model";

export type AskStage =
  | "received" | "queued" | "handed_over" | "grant" | "container" | "answered" | "failed" | "resumed";

/** One stage of a turn, as one structured log line. `turn` is the question's id; the first 8 characters name it. */
export function askEvent(stage: AskStage, turn: string, fields: Record<string, unknown> = {}): void {
  console.log("ask_event", { turn, stage, ...fields });
}

/** A failure that knows its side, so the chat can say which part let the question down. */
export class AskFailure extends Error {
  readonly side: AskSide;
  readonly status: number | null;

  constructor(side: AskSide, message: string, status: number | null = null) {
    super(message);
    this.side = side;
    this.status = status;
  }
}

/** Anything shaped like a GitHub or Anthropic credential, wherever it turns up in an error. */
const CREDENTIALS = /\b(gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|sk-ant-[A-Za-z0-9_-]{16,})/g;

/** `text` with every credential in it, and each of `known`, replaced: errors pass through the chat and the logs. */
export function scrubbed(text: string, known: readonly (string | null | undefined)[] = []): string {
  return known.reduce<string>((clean, secret) => (secret && secret.length >= 8 ? clean.split(secret).join("[redacted]") : clean),
    text.replace(CREDENTIALS, "[redacted]"));
}

/** The error's own words with its kind, which a bare `console.error(error)` loses in Workers Logs; no credential in it. */
export function errorWords(error: unknown, known: readonly (string | null | undefined)[] = []): string {
  if (error instanceof Error) {
    const words = error.message.trim() || "(no message)";
    return scrubbed(error.name && error.name !== "Error" ? `${error.name}: ${words}` : words, known);
  }
  return scrubbed(String(error), known);
}

/** The side of a failure: told by an `AskFailure`, else this Worker's own. */
export function sideOf(error: unknown): AskSide {
  return error instanceof AskFailure ? error.side : "worker";
}

/** The chat's line for a failed turn: what failed, technically, and the turn's id to look it up by. */
export function failedLine(error: unknown, turn: string, known: readonly (string | null | undefined)[] = []): string {
  const status = error instanceof AskFailure && error.status !== null ? ` ${error.status}` : "";
  return `${sideName[sideOf(error)]}${status}: ${errorWords(error, known)} · turn ${turn.slice(0, 8)}`;
}

const sideName: Record<AskSide, string> = {
  app: "App request", worker: "PRHub Worker", github: "GitHub", container: "AI container", model: "Claude",
};
