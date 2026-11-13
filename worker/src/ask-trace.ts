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

/** The error's own words with its kind, which a bare `console.error(error)` loses in Workers Logs. */
export function errorWords(error: unknown): string {
  if (error instanceof Error) {
    const words = error.message.trim() || "(no message)";
    return error.name && error.name !== "Error" ? `${error.name}: ${words}` : words;
  }
  return String(error);
}

/** The side of a failure: told by an `AskFailure`, else this Worker's own. */
export function sideOf(error: unknown): AskSide {
  return error instanceof AskFailure ? error.side : "worker";
}

/** The chat's line for a failed turn: what failed, technically, and the turn's id to look it up by. */
export function failedLine(error: unknown, turn: string): string {
  const status = error instanceof AskFailure && error.status !== null ? ` ${error.status}` : "";
  return `${sideName[sideOf(error)]}${status}: ${errorWords(error)} · turn ${turn.slice(0, 8)}`;
}

const sideName: Record<AskSide, string> = {
  app: "App request", worker: "PRHub Worker", github: "GitHub", container: "AI container", model: "Claude",
};
