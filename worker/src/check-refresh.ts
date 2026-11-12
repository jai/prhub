/**
 * A checks-only read (`readChecks`) laid over what the index holds for a PR: the same row and detail a full read would
 * make, when only checks moved. Anything else having moved (the head, or `updatedAt`) needs the full read.
 */
import { type ChecksNode, checksRead, type Detail, type OpenRowStatus } from "./github.ts";
import type { PeopleDecision } from "./policy-people.ts";

/** What the index holds for a PR, as a full read stored it. */
export interface HeldRead {
  head: string;
  updatedAt: string;
  status: OpenRowStatus;
  detail: Detail;
  people: PeopleDecision | null;
}

export interface PatchedRead {
  version: string;
  status: OpenRowStatus;
  detail: Detail;
}

/** The held read with these checks; null when the PR moved past what checks change, so it is read in full. */
export function patchedRead(held: HeldRead, node: ChecksNode): PatchedRead | null {
  if (node.headRefOid !== held.head || node.updatedAt !== held.updatedAt) {
    return null;
  }
  const { version, checks, review, merge, detail } = checksRead(node, held.people);
  return {
    version,
    status: { ...held.status, checks, review, merge },
    detail: { ...held.detail, ...detail },
  };
}
