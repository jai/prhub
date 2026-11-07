import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { type Membership, type PeopleFacts, parsePolicy, peopleDecision } from "../src/policy-people.ts";

/**
 * Real PRs, captured by scripts/capture-policy-cases.mts and checked against PolicyBot by hand: the people count must
 * keep answering what it answered for them. A membership the capture never asked about fails the case loudly.
 */
interface Case {
  ref: string;
  policy: string | null;
  facts: PeopleFacts;
  members: Record<string, boolean>;
  expected: string | null;
  policyBot: string | null;
}

const fixture = JSON.parse(readFileSync(new URL("./fixtures/policy-cases.json", import.meta.url), "utf8")) as {
  policies: Record<string, string>;
  cases: Case[];
};

for (const one of fixture.cases) {
  test(`${one.ref} reads ${one.expected ?? "no policy"} (PolicyBot: ${one.policyBot ?? "none"})`, async () => {
    const policy = one.policy === null ? null : parsePolicy(fixture.policies[one.policy] ?? "");
    const known = (key: string) => {
      assert.ok(key in one.members, `${one.ref} asks about ${key}, which the capture never recorded`);
      return one.members[key] ?? null;
    };
    const members: Membership = {
      inTeam: async (team, login) => known(`team:${team}:${login}`),
      inOrg: async (org, login) => known(`org:${org}:${login}`),
    };
    assert.equal(policy ? await peopleDecision(policy, one.facts, members) : null, one.expected);
  });
}
