/**
 * A checks-only read (`readChecks`) laid over what the index holds for a PR: the same row and detail a full read would
 * make, when only checks moved. Anything else having moved (the head, or `updatedAt`) needs the full read.
 */
import { type ChecksNode, checksRead, type Detail, type OpenRowStatus } from "./github.ts";
import { POLICY_TTL_MS } from "./policy-github.ts";
import type { PeopleDecision } from "./policy-people.ts";

/** What the index holds for a PR, as a full read stored it. */
export interface HeldRead {
  head: string;
  updatedAt: string;
  status: OpenRowStatus;
  detail: Detail;
  people: PeopleDecision | null;
  /** When the full read that decided `people` ran. */
  peopleAt: number;
}

export interface PatchedRead {
  version: string;
  status: OpenRowStatus;
  detail: Detail;
}

/**
 * The held read with these checks; null when it is read in full instead: the PR moved past what checks change, or the
 * people decision may be out of date. That decision outranks PolicyBot's live status (`reviewDecisionOf`), so it is
 * trusted only as long as `.policy.yml` is, and a null one (no policy, or one that could not be read) never.
 */
export function patchedRead(held: HeldRead, node: ChecksNode, now: number): PatchedRead | null {
  if (node.headRefOid !== held.head || node.updatedAt !== held.updatedAt || held.people === null
    || now - held.peopleAt >= POLICY_TTL_MS) {
    return null;
  }
  const { version, checks, review, merge, detail } = checksRead(node, held.people);
  return {
    version,
    status: { ...held.status, checks, review, merge },
    detail: { ...held.detail, ...detail },
  };
}
