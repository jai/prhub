/**
 * Retention of what R2 keeps for a PR no longer on the list (docs/api.md, "Limits"): its diffs, details, AI answers and
 * Ask record go once the newest of them is older than `closed_pull_request_retention_days`. A PR still on the list keeps
 * everything. The sweep reads the state that exists (the bucket and the index) each time, so a run cut short is
 * finished by the next one.
 */
import { parseRepoFullName, prId, type PrId } from "./ids.ts";

/** The objects one PR leaves under a prefix (`scopedKey`): `pr-index.ts` diffs and details, `ai-run.ts`, `ask-chat.ts`. */
const PULL_REQUEST_OBJECTS = [
  /^([\w.-]+)\/([\w.-]+)\/(\d+)\/[^/]+\.diff$/,
  /^([\w.-]+)\/([\w.-]+)\/(\d+)\/detail\/[^/]+\.json$/,
  /^ai\/([\w.-]+)\/([\w.-]+)\/(\d+)\/[^/]+\/[^/]+\.json$/,
  /^ask\/([\w.-]+)\/([\w.-]+)\/(\d+)\.json$/,
];

/** The PR a stored key belongs to, below `prefix`; null for anything else (the repo index, setup, pairing). */
export function pullRequestOfKey(key: string, prefix: string): PrId | null {
  if (!key.startsWith(prefix)) {
    return null;
  }
  const rest = key.slice(prefix.length);
  for (const pattern of PULL_REQUEST_OBJECTS) {
    const match = pattern.exec(rest);
    const repo = match && parseRepoFullName(`${match[1]}/${match[2]}`);
    if (match && repo) {
      return prId(repo, Number(match[3]));
    }
  }
  return null;
}

/** The slice of `R2Bucket` the sweep uses. */
type RetentionBucket = Pick<R2Bucket, "list" | "delete">;

/**
 * Deletes every object of each PR `isHeld` says is gone whose newest object was stored before `cutoff`. Answers how
 * many objects went.
 */
export async function sweepClosedPullRequests(
  bucket: RetentionBucket, prefix: string, isHeld: (id: PrId) => boolean, cutoff: number,
): Promise<number> {
  const byPullRequest = new Map<PrId, { keys: string[]; newest: number }>();
  let cursor: string | undefined;
  do {
    const listed = await bucket.list({ prefix, cursor, limit: 1_000 });
    for (const object of listed.objects) {
      const id = pullRequestOfKey(object.key, prefix);
      if (id && !isHeld(id)) {
        const entry = byPullRequest.get(id) ?? { keys: [], newest: 0 };
        entry.keys.push(object.key);
        entry.newest = Math.max(entry.newest, object.uploaded.getTime());
        byPullRequest.set(id, entry);
      }
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  const expired = [...byPullRequest.values()].filter((entry) => entry.newest < cutoff).flatMap((entry) => entry.keys);
  for (let start = 0; start < expired.length; start += 1_000) {
    await bucket.delete(expired.slice(start, start + 1_000));
  }
  return expired.length;
}
