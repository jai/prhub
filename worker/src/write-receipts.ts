/**
 * The phone's writes arrive at least once: its outbox sends again until it hears back. Each
 * carries a `client_ref`, and its receipt here makes a repeat answer as the first did, without posting twice.
 */

export type WriteClaim = "go" | "done" | "busy";

export type WriteReceipt = {
  state: "sending" | "done";
  at: number;
};

/** A copy still sending after this is taken as lost and sent again: the Worker died with GitHub's answer unread. */
export const SENDING_FOR_MS = 120_000;
/** The outbox gives up after a day; this outlasts it. */
export const RECEIPT_KEPT_MS = 7 * 24 * 3_600_000;

export function claimOf(receipt: WriteReceipt | null, now: number): WriteClaim {
  if (receipt?.state === "done") {
    return "done";
  }
  return receipt && now - receipt.at < SENDING_FOR_MS ? "busy" : "go";
}

/** The phone's key for one write: 1 to 100 characters, or none from a build before the outbox. */
export function clientRefOf(input: unknown): string | null {
  const ref = (input as { client_ref?: unknown } | null)?.client_ref;
  return typeof ref === "string" && ref.length >= 1 && ref.length <= 100 ? ref : null;
}

/** Another copy is on its way to GitHub: the phone tries again shortly. */
export function busyAnswer(): Response {
  return Response.json({ error: "This is already being sent." }, { status: 503, headers: { "Retry-After": "10" } });
}
