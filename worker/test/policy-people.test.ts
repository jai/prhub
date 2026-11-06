import assert from "node:assert/strict";
import test from "node:test";
import { type Membership, type PeopleFacts, parsePolicy, peopleDecision } from "../src/policy-people.ts";

const POLICY = `
policy:
  approval:
    - or:
        - devops bypass
        - review pool
        - review pool without automatic requests
    - size workflow change
  disapproval:
    requires:
      organizations: [Acme]
approval_rules:
  - name: size workflow change
    if:
      changed_files:
        paths: ["^\\\\.github/workflows/pr-size-gate\\\\.yaml$"]
    options: { allow_author: false, invalidate_on_push: true }
    requires: { count: 1, users: [jai, poom] }
  - name: devops bypass
    if:
      has_author_in: { users: [acme-devops] }
    requires: { count: 0 }
  - name: review pool
    if:
      targets_branch: { pattern: "^(main|develop)$" }
      title: { not_matches: ["^release:"] }
    options: { allow_author: false, invalidate_on_push: false }
    requires: &pool
      count: 2
      teams: [Acme/backend]
      conditions:
        has_status: { conclusions: [success], statuses: [pre-commit-check] }
  - name: review pool without automatic requests
    if:
      targets_branch: { pattern: "^(main|develop)$" }
      title: { not_matches: ["^release:"] }
    requires: *pool
`;

const BACKEND = new Set(["anzor", "poom", "aymen", "hussein"]);
const members: Membership = {
  inTeam: async (team, login) => team === "Acme/backend" && BACKEND.has(login),
  inOrg: async (_org, login) => login !== "outsider",
};

function pr(over: Partial<PeopleFacts> = {}): PeopleFacts {
  return {
    base: "main", title: "feat: push payments", author: "hussein", files: ["src/payments.ts"], committers: ["hussein"],
    headAt: "2026-11-06T07:00:00Z", labels: [], reviews: [], comments: [], ...over,
  };
}

const approve = (login: string, at = "2026-10-27T03:44:00Z") => ({ login, state: "APPROVED", submittedAt: at });
const policy = parsePolicy(POLICY)!;

test("two people from the pool approve it, whatever its checks say", async () => {
  assert.equal(await peopleDecision(policy, pr({ reviews: [approve("anzor"), approve("poom")] }), members), "APPROVED");
});

test("one approval of two is still waiting on people", async () => {
  assert.equal(await peopleDecision(policy, pr({ reviews: [approve("anzor")] }), members), "REVIEW_REQUIRED");
});

test("the author's own approval and someone outside the pool don't count", async () => {
  const reviews = [approve("hussein"), approve("anzor"), approve("stranger")];
  assert.equal(await peopleDecision(policy, pr({ reviews }), members), "REVIEW_REQUIRED");
});

test("a pool member who pushed a commit is a contributor and doesn't count", async () => {
  const facts = pr({ committers: ["hussein", "poom"], reviews: [approve("anzor"), approve("poom")] });
  assert.equal(await peopleDecision(policy, facts, members), "REVIEW_REQUIRED");
});

test("a rule that applies to a file needs its own approver, after the last push where it says so", async () => {
  const files = ["src/payments.ts", ".github/workflows/pr-size-gate.yaml"];
  const both = [approve("anzor"), approve("aymen")];
  assert.equal(await peopleDecision(policy, pr({ files, reviews: both }), members), "REVIEW_REQUIRED");
  const stale = [...both, approve("jai", "2026-11-01T00:00:00Z")];
  assert.equal(await peopleDecision(policy, pr({ files, reviews: stale }), members), "REVIEW_REQUIRED");
  const fresh = [...both, approve("jai", "2026-11-06T08:00:00Z")];
  assert.equal(await peopleDecision(policy, pr({ files, reviews: fresh }), members), "APPROVED");
});

test("a rule with no people to wait for passes for the author it names", async () => {
  assert.equal(await peopleDecision(policy, pr({ author: "acme-devops" }), members), "APPROVED");
});

test("a change request from someone the policy lists is a change request", async () => {
  const reviews = [approve("anzor"), approve("poom"), { login: "aymen", state: "CHANGES_REQUESTED", submittedAt: null }];
  assert.equal(await peopleDecision(policy, pr({ reviews }), members), "CHANGES_REQUESTED");
});

test("a 👍 comment counts as an approval by default", async () => {
  const comments = [{ login: "aymen", body: "👍 ship it", createdAt: "2026-11-06T09:00:00Z" }];
  assert.equal(await peopleDecision(policy, pr({ reviews: [approve("anzor")], comments }), members), "APPROVED");
});

test("a policy whose every rule is skipped passes", async () => {
  assert.equal(await peopleDecision(policy, pr({ base: "feature/x" }), members), "APPROVED");
});

test("membership GitHub won't answer leaves the decision to PolicyBot", async () => {
  const unknown: Membership = { inTeam: async () => null, inOrg: async () => true };
  assert.equal(await peopleDecision(policy, pr({ reviews: [approve("anzor"), approve("poom")] }), unknown), null);
});

test("a file that isn't a policy is not read as one", () => {
  assert.equal(parsePolicy("just: text"), null);
  assert.equal(parsePolicy("::: not yaml"), null);
});
