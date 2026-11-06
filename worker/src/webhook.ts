/** A delivery says a PR may have changed, never what it is now: the index reads GitHub for that. */
export interface PullRequestMark {
  repo: string;
  number: number;
  /** Jai is the author or a requested reviewer, so a PR the index does not hold yet still counts. */
  involved: boolean;
}

interface Payload {
  repository?: { full_name?: string };
  requested_reviewer?: { login?: string };
  issue?: { number?: number; pull_request?: unknown; user?: { login?: string } };
  pull_request?: {
    number?: number;
    user?: { login?: string };
    requested_reviewers?: { login?: string }[];
  };
}

const PULL_REQUEST_EVENTS = new Set([
  "pull_request", "pull_request_review", "pull_request_review_comment", "pull_request_review_thread",
]);

function hexBytes(hex: string): Uint8Array<ArrayBuffer> | null {
  if (hex.length !== 64 || !/^[0-9a-f]+$/.test(hex)) {
    return null;
  }
  return Uint8Array.from(hex.match(/../g) ?? [], (byte) => parseInt(byte, 16));
}

/** The HMAC of the exact bytes GitHub sent, checked before anything parses them. */
export async function verifySignature(body: ArrayBuffer, header: string | null, secret: string): Promise<boolean> {
  const signature = header?.startsWith("sha256=") ? hexBytes(header.slice(7)) : null;
  if (!signature) {
    return false;
  }
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  return crypto.subtle.verify("HMAC", key, signature, body);
}

export function parseDelivery(event: string | null, body: string, login: string): PullRequestMark | null {
  const isComment = event === "issue_comment";
  if (!event || (!isComment && !PULL_REQUEST_EVENTS.has(event))) {
    return null;
  }
  const { repository, requested_reviewer: requested, issue, pull_request: pr } = JSON.parse(body) as Payload;
  const number = isComment ? (issue?.pull_request ? issue.number : undefined) : pr?.number;
  if (!repository?.full_name || !number) {
    return null;
  }
  return {
    repo: repository.full_name,
    number,
    involved: pr?.user?.login === login || issue?.user?.login === login || requested?.login === login
      || (pr?.requested_reviewers ?? []).some((reviewer) => reviewer.login === login),
  };
}
