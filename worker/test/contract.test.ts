import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { test } from "node:test";
import { alertMessage } from "../src/alerts.ts";
import { parseRowStatus } from "../src/boundary.ts";
import { deviceConfig } from "../src/config.ts";
import type { Env } from "../src/env.ts";
import { detailVersionOf, mergedRow, pullRequest, reviewWeek } from "../src/github.ts";
import type { RepoFullName, Sha } from "../src/ids.ts";
import { DEFAULT_CONTEXT } from "../src/key-lines.ts";
import { stateOf } from "../src/pr-states.ts";
import { prNode } from "./pr-node.ts";

const WEEK = reviewWeek({ REVIEW_SLA_UTC_OFFSET_HOURS: "7", REVIEW_SLA_HOURS: "9-18", REVIEW_SLA_WEEKDAYS: "1,2,3,4,5" });

function read(overrides: Record<string, unknown> = {}) {
  return pullRequest(prNode(overrides) as never, "jai", false, WEEK, null);
}

test("a row and its detail say the same merge state and review, a lagging merge state among them", () => {
  const cases: [string, string, string][] = [
    ["CONFLICTING", "BEHIND", "conflicting"],
    ["CONFLICTING", "CLEAN", "conflicting"],
    ["MERGEABLE", "BEHIND", "behind"],
    ["MERGEABLE", "CLEAN", "clean"],
    ["UNKNOWN", "BLOCKED", "blocked"],
  ];
  for (const [mergeable, mergeStateStatus, merge] of cases) {
    const pr = read({ mergeable, mergeStateStatus });
    assert.equal(pr.detail.merge, merge, `${mergeable}/${mergeStateStatus}`);
    assert.equal(pr.status?.merge, pr.detail.merge, `${mergeable}/${mergeStateStatus}`);
    assert.equal(pr.status?.review, pr.detail.review);
    assert.equal(pr.detail.mergeState, mergeStateStatus, "the raw state stays for older app builds");
  }
});

test("a draft is on no list, and its detail says blocked as the threads' PR state does", () => {
  const node = prNode({ isDraft: true, mergeStateStatus: "DRAFT" });
  const pr = pullRequest(node as never, "jai", false, WEEK, null);
  assert.equal(pr.status, null);
  assert.equal(pr.detail.merge, "blocked");
  assert.equal(stateOf(node as never, "jai").merge, pr.detail.merge);
  assert.equal(stateOf(node as never, "jai").review, pr.detail.review);
});

test("the review decision reads as the row's review on the detail", () => {
  assert.equal(read({ reviewDecision: "APPROVED" }).detail.review, "approved");
  assert.equal(read({ reviewDecision: "CHANGES_REQUESTED" }).detail.review, "changes_requested");
  assert.equal(read({ reviewDecision: null }).detail.review, "none");
});

// Golden fixtures (docs/fixtures/): what the Worker sends, from the real builders, for the app's contract tests.
// `UPDATE_FIXTURES=1 npm test` writes them after a deliberate change; otherwise a change fails here.
const FIXTURES = new URL("../../docs/fixtures/", import.meta.url);

function matchesFixture(name: string, value: unknown): void {
  const text = `${JSON.stringify(value, null, 2)}\n`;
  const file = new URL(name, FIXTURES);
  if (process.env.UPDATE_FIXTURES === "1") {
    writeFileSync(file, text);
  }
  assert.equal(readFileSync(file, "utf8"), text, `${name} changed: run UPDATE_FIXTURES=1 npm test and review the diff`);
}

test("a row of GET /prs, on the review list", async () => {
  const pr = read();
  assert.ok(pr.status);
  // As `PrIndex.rows` serves it: the status as stored and read back.
  matchesFixture("row.json", {
    repo: pr.repo, number: pr.number, title: pr.title, head: pr.head, revision: pr.revision, diff: "ready",
    detail: await detailVersionOf(pr), status: parseRowStatus(JSON.stringify(pr.status)), keyLines: DEFAULT_CONTEXT,
  });
});

test("a row of GET /prs/merged", () => {
  matchesFixture("merged-row.json", mergedRow({
    number: 9, title: "Ship the uploader", headRefOid: "1111111111111111111111111111111111111111", baseRefName: "main",
    updatedAt: "2026-11-01T00:05:00Z", mergedAt: "2026-11-01T00:04:00Z", additions: 10, deletions: 2, changedFiles: 3,
    author: { login: "jai" }, repository: { nameWithOwner: "acme/app" },
  }));
});

test("a detail, as the index keeps it", () => {
  matchesFixture("detail.json", read({ mergeable: "CONFLICTING", mergeStateStatus: "CLEAN" }).detail);
});

test("GET /device/config", () => {
  const env = {
    GITHUB_TOKEN: "t", ANTHROPIC_API_KEY: "k", PUSH_RELAY_URL: "https://relay", PUSH_RELAY_KEY: "rks_x",
    GITHUB_ORGS: "acme",
  } as Env;
  matchesFixture("device-config.json", deviceConfig(env, "alex"));
});

test("an alert's push payload", () => {
  const alert = {
    kind: "review_requested" as const, repo: "acme/app" as RepoFullName, number: 7,
    head: "504754b2bc3ce5db892dde980e4bc83b60ff7a68" as Sha, title: "Add the retry to the uploader",
  };
  matchesFixture("alert.json", alertMessage(alert).payload);
});
