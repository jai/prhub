/**
 * A `GET …/ask` the Worker holds while the chat stays as the phone last read it (docs/api.md, "Asking"). It answers a
 * changed chat at once, and `204` when nothing changed. Nothing here calls anything: `HeldAsk` is the chat and the queue.
 */
import type { AskChat } from "./ask-chat.ts";

/** The chat's version, on every answer the Worker can hold. A phone without it, and a Worker that can't hold, poll. */
export const ASK_VERSION = "Ask-Version";
/** Under the 15 seconds the apps give a request. */
export const ASK_HELD_MS = 10_000;

export interface HeldAsk {
  /** Read before `chat`, so a change between the two ends `wait` at once. */
  now(): Promise<{ version: number; activity: string | null }>;
  chat(): Promise<AskChat>;
  wait(seen: number, ms: number): Promise<void>;
  clock(): number;
}

/** How long the phone lets this read wait, from `?wait=` in seconds; 0 when it doesn't. */
export function askWaitMs(url: URL): number {
  const seconds = Number(url.searchParams.get("wait") ?? 0);
  return Number.isFinite(seconds) ? Math.min(Math.max(seconds, 0) * 1_000, ASK_HELD_MS) : 0;
}

async function versionOf(body: string): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body));
  return [...new Uint8Array(hash).slice(0, 12)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/** `url`: `wait` and `version`, what the phone last read. Only a working chat is held: one at rest is answered at once. */
export async function heldAsk(url: URL, held: HeldAsk): Promise<Response> {
  const seen = url.searchParams.get("version");
  const until = held.clock() + askWaitMs(url);
  for (;;) {
    const { version, activity } = await held.now();
    const read = await held.chat();
    const chat = read.isWorking && activity !== null ? { ...read, activity } : read;
    const body = JSON.stringify(chat);
    const tag = await versionOf(body);
    const headers = { [ASK_VERSION]: tag, "Cache-Control": "no-store" };
    const left = until - held.clock();
    if (tag !== seen) {
      return new Response(body, { headers: { ...headers, "Content-Type": "application/json" } });
    }
    if (!chat.isWorking || left <= 0) {
      return new Response(null, { status: 204, headers });
    }
    await held.wait(version, left);
  }
}
