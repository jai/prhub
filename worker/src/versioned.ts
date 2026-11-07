/**
 * Copies in R2 kept under a version: a diff under its revision, a detail under its detail version. A copy is good for
 * ever, so one may be stored only under the version it was computed from. A live read says which version it got, and
 * only a read of the version asked for is kept.
 */

/** What a live read got, and of which version. Null: it can't be told, so it is never kept. */
export interface LiveRead {
  response: Response;
  version: string | null;
}

/** The part of the R2 bucket this needs; a test passes a fake. */
export type VersionStore = Pick<R2Bucket, "get" | "head" | "put">;

/** Who wrote a copy and for which version, in its custom metadata. A copy without it predates the check. */
export const VERSION_METADATA = "version";

function versionOf(object: { customMetadata?: Record<string, string> } | null): string | null {
  return object?.customMetadata?.[VERSION_METADATA] ?? null;
}

export function putVersioned(store: VersionStore, key: string, version: string, value: ArrayBuffer | string,
  contentType: string): Promise<unknown> {
  return store.put(key, value, { httpMetadata: { contentType }, customMetadata: { [VERSION_METADATA]: version } });
}

/**
 * R2, then GitHub. A live read of another version than the one asked for (the head moved since the list was read) is
 * answered, as GitHub has it now, but not kept: it would stand for the old version for ever.
 */
export async function serveVersioned(
  store: VersionStore, key: string, requested: string, contentType: string, load: () => Promise<LiveRead>,
  waitUntil: (promise: Promise<unknown>) => void,
): Promise<Response> {
  const stored = await store.get(key);
  if (stored) {
    return new Response(stored.body, { headers: { "Content-Type": contentType } });
  }
  const live = await load();
  if (!live.response.ok) {
    return live.response;
  }
  const bytes = await live.response.arrayBuffer();
  if (live.version === requested) {
    waitUntil(putVersioned(store, key, requested, bytes.slice(0), contentType));
  }
  return new Response(bytes, { headers: { "Content-Type": contentType } });
}

export type DiffState = "ready" | "too_large" | "pending";

/**
 * The index's copy of a row's diff. Ready only from a copy known to be of this revision: one stored with it, or a live
 * read that was of it. A read of another revision leaves the row pending; the index reads the PR again anyway.
 */
export async function storeDiff(
  store: VersionStore, key: string, revision: string, load: () => Promise<LiveRead>,
): Promise<DiffState> {
  if (versionOf(await store.head(key)) === revision) {
    return "ready";
  }
  const live = await load();
  if (live.version !== revision) {
    return "pending";
  }
  if (live.response.ok) {
    await putVersioned(store, key, revision, await live.response.arrayBuffer(), "text/plain");
    return "ready";
  }
  return live.response.status === 406 ? "too_large" : "pending";
}
