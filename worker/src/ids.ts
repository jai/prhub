/**
 * The Worker's identities as types. Each brand has one way in, so a plain string can't stand for one by mistake:
 * a `Sha` from `parseSha` (or `shaOf`, for GitHub's own answers), a `Revision` from `revisionOf`, a `Fingerprint` and
 * a `CodeHash` from `pairing.ts`, a `RepoFullName` from `parseRepoFullName` (or `repoOf`), a `PrId` from `prId`.
 */

declare const brand: unique symbol;
export type Brand<T, Name extends string> = T & { readonly [brand]: Name };

/** A commit: 40 lowercase hex characters. */
export type Sha = Brand<string, "Sha">;

/** What a diff is computed from: the head commit and the branch it is compared with (`revisionOf`). */
export type Revision = Brand<`${string}-${string}`, "Revision">;

const SHA = /^[0-9a-f]{40}$/;

/** A commit sent by a client or read from storage; null when it is not one. */
export function parseSha(raw: unknown): Sha | null {
  return typeof raw === "string" && SHA.test(raw) ? raw as Sha : null;
}

/** A commit GitHub named. Anything else means its answer is not what this code reads, so the read fails. */
export function shaOf(raw: string): Sha {
  const sha = parseSha(raw);
  if (!sha) {
    throw new Error(`GitHub named a commit that is not one: ${JSON.stringify(raw).slice(0, 60)}`);
  }
  return sha;
}

/** A base that only moves on leaves it alone; a retarget changes it. The branch is made safe for a file name. */
export function revisionOf(head: Sha, baseBranch: string): Revision {
  return `${head}-${baseBranch.replace(/[^\w.-]/g, "_")}` as Revision;
}

/** Whether a revision is of this head, whatever the base. */
export function isRevisionOf(revision: Revision, head: Sha): boolean {
  return revision.startsWith(`${head}-`);
}

/** SHA-256 of a device secret, lowercase hex: what the index keeps of a paired app (`fingerprintOf`). */
export type Fingerprint = Brand<string, "Fingerprint">;

/** SHA-256 of a pairing code, lowercase hex: the code's name in R2 and in the spent codes (`codeHashOf`). */
export type CodeHash = Brand<string, "CodeHash">;

/** A device's APNs token: hex, as Apple gives it, lowercased (the relay's rule, relay/src/validate.ts). */
export type DeviceToken = Brand<string, "DeviceToken">;

/** `owner/name`, as GitHub names a repo. */
export type RepoFullName = Brand<`${string}/${string}`, "RepoFullName">;

/** One PR: `owner/name#number`. Made by `prId` alone. */
export type PrId = Brand<`${string}/${string}#${number}`, "PrId">;

const REPO = /^([\w.-]+)\/([\w.-]+)$/;

/** A repo named by a client, a URL or storage; null when it is not `owner/name`. */
export function parseRepoFullName(raw: unknown): RepoFullName | null {
  return typeof raw === "string" && REPO.test(raw) ? raw as RepoFullName : null;
}

/** A repo GitHub named. Anything else means its answer is not what this code reads, so the read fails. */
export function repoOf(raw: string): RepoFullName {
  const repo = parseRepoFullName(raw);
  if (!repo) {
    throw new Error(`GitHub named a repo that is not owner/name: ${JSON.stringify(raw).slice(0, 120)}`);
  }
  return repo;
}

/** The owner and the name, as GraphQL's `repository(owner:, name:)` takes them. */
export function repoParts(repo: RepoFullName): { owner: string; name: string } {
  const [, owner, name] = REPO.exec(repo) as RegExpExecArray;
  return { owner, name };
}

export function prId(repo: RepoFullName, number: number): PrId {
  return `${repo}#${number}` as PrId;
}
