import type { AskChat } from "../../src/ask-chat.ts";
import { askPr, type QueuedAsk } from "../../src/ask-queue.ts";
import type { RepoFullName, Sha } from "../../src/ids.ts";

const HEAD = "a".repeat(40) as Sha;
const REPO = "acme/api" as RepoFullName;
export const PR = askPr(REPO, 7);

export function question(id: string, words: string, at = 1_000): QueuedAsk {
  return {
    id,
    repo: REPO,
    number: 7,
    input: { question: words, head: HEAD, anchor: null },
    choice: { model: "claude-haiku-5-5", effort: "high" },
    at,
    error: null,
  };
}

export const ANSWERED: AskChat = {
  messages: [
    { id: "m1", role: "you", text: "What does it change?", anchor: null },
    { id: "m2", role: "agent", text: "The retry.", anchor: null },
  ],
  isWorking: false,
  activity: null,
  problem: null,
  costCents: 3,
  model: "claude-haiku-5-5",
  effort: "high",
};
