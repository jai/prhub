import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { test } from "node:test";
import { URL } from "node:url";
import { type RepoFullName, type Sha } from "../../../src/ids.ts";
import { alertMessage } from "../../../src/alerts.ts";
import { parseRowStatus } from "../../../src/boundary.ts";
import { deviceConfig } from "../../../src/config.ts";
import type { Env } from "../../../src/env.ts";
import { detailVersionOf, mergedRow, pullRequest, reviewWeek } from "../../../src/github.ts";
import { DEFAULT_CONTEXT } from "../../../src/key-lines.ts";

import { resolvedTickets, rowTickets } from "../../../src/tickets.ts";
import { authenticate, hostedAccountConfig } from "../../../src/hosted.ts";
import { bearer, hostedWorld, ORIGIN, signIn } from "../../support/hosted-world.ts";
import { prNode } from "../../support/pr-node.ts";

const WEEK = reviewWeek({
  REVIEW_SLA_UTC_OFFSET_HOURS: "7",
  REVIEW_SLA_HOURS: "9-18",
  REVIEW_SLA_WEEKDAYS: "1,2,3,4,5",
});

function read(overrides: Record<string, unknown> = {}) {
  return pullRequest(prNode(overrides) as never, "jai", false, WEEK, null);
}

// Golden fixtures (PRKit/Tests/PRContractFixtures/Fixtures/): what the Worker sends, from the real builders, for the app's contract tests.
// `UPDATE_FIXTURES=1 npm test` writes them after a deliberate change; otherwise a change fails here.
const FIXTURES = new URL("../../../../PRKit/Tests/PRContractFixtures/Fixtures/", import.meta.url);

function matchesFixture(name: string, value: unknown): void {
  const text = `${JSON.stringify(value, null, 2)}\n`;
  const file = new URL(name, FIXTURES);
  if (process.env.UPDATE_FIXTURES === "1") {
    writeFileSync(file, text);
  }
  assert.equal(
    readFileSync(file, "utf8"),
    text,
    `${name} changed: run UPDATE_FIXTURES=1 npm test and review the diff`,
  );
}

test("a row of GET /prs, on the review list, with the ticket its branch names", async () => {
  const pr = read({ headRefName: "alex/eng-7-retry" });
  assert.ok(pr.status);
  // As `readPullRequests` fills it, with Linear's answer.
  pr.detail.tickets = resolvedTickets(
    pr.ticketKeys,
    new Map([
      [
        "ENG-7",
        {
          key: "ENG-7",
          url: "https://linear.app/acme/issue/ENG-7/retry-uploads",
          title: "Retry failed uploads",
          state: "In Progress",
          state_type: "started",
          state_color: "#f2c94c",
          assignee: "Alex Doe",
          found: true,
        },
      ],
    ]),
  );
  pr.tickets = rowTickets(pr.ticketKeys, pr.detail.tickets);
  pr.ticket = pr.tickets[0] ?? null;
  // As `PrIndex.rows` serves it: the status as stored and read back.
  matchesFixture("row.json", {
    repo: pr.repo,
    number: pr.number,
    title: pr.title,
    head: pr.head,
    revision: pr.revision,
    diff: "ready",
    detail: await detailVersionOf(pr),
    status: parseRowStatus(JSON.stringify(pr.status)),
    keyLines: DEFAULT_CONTEXT,
    ticket: pr.ticket,
    tickets: pr.tickets,
  });
});

test("a row of GET /prs/merged", () => {
  matchesFixture(
    "merged-row.json",
    mergedRow({
      number: 9,
      title: "Ship the uploader",
      headRefOid: "1111111111111111111111111111111111111111",
      baseRefName: "main",
      updatedAt: "2026-11-01T00:05:00Z",
      mergedAt: "2026-11-01T00:04:00Z",
      additions: 10,
      deletions: 2,
      changedFiles: 3,
      author: { login: "jai" },
      repository: { nameWithOwner: "acme/app" },
    }),
  );
});

test("a detail, as the index keeps it", () => {
  matchesFixture(
    "detail.json",
    read({
      mergeable: "CONFLICTING",
      mergeStateStatus: "CLEAN",
      title: "Add the retry to the uploader [ENG-7]",
    }).detail,
  );
});

test("GET /device/config", () => {
  const env = {
    GITHUB_TOKEN: "t",
    AI_ON_API_KEY: "on",
    ANTHROPIC_API_KEY: "k",
    APNS_BUNDLE_ID: "b",
    APNS_KEY_ID: "i",
    APNS_TEAM_ID: "t",
    APNS_KEY_P8: "p",
    GITHUB_ORGS: "acme",
  } as Env;
  matchesFixture(
    "device-config.json",
    deviceConfig(env, "alex", {
      internal: { version: "1.0", build: "212" },
      public: { version: "1.0", build: "198" },
    }),
  );
});

test("GET /device/config on the hosted Worker: the hosted limits, the account and its installations", async () => {
  const world = hostedWorld();
  world.github.installations.set(1, { account: "octocat", repos: ["octocat/hello"], type: "User" });
  world.github.installations.set(2, {
    account: "acme",
    repos: ["acme/api", "acme/web"],
    selection: "selected",
  });
  world.github.grant(world.github.user, ["octocat/hello", "acme/api", "acme/web"]);
  const secret = await signIn(world);
  const auth = await authenticate(
    new Request(`${ORIGIN}/device/config`, bearer(secret)),
    world.workerEnv,
    world.services,
  );
  assert.ok("env" in auth);
  matchesFixture("device-config-hosted.json", {
    ...deviceConfig({ HOSTED: "on", GITHUB_TOKEN: "ghu_x" } as Env, "octocat"),
    ...hostedAccountConfig(
      auth.session,
      await world.services.account(auth.session.userId).installationAccounts(),
    ),
  });
});

test("an alert's push payload", () => {
  const alert = {
    kind: "review_requested" as const,
    repo: "acme/app" as RepoFullName,
    number: 7,
    head: "504754b2bc3ce5db892dde980e4bc83b60ff7a68" as Sha,
    title: "Add the retry to the uploader",
  };
  const row = {
    repo: alert.repo,
    number: alert.number,
    title: alert.title,
    head: alert.head,
    revision: `${alert.head}-main`,
    diff: "ready",
    detail: "2026-11-01T00:05:00Z.SUCCESS.0123456789abcdef",
    status: null,
    keyLines: DEFAULT_CONTEXT,
    ticket: null,
    tickets: [],
  };
  matchesFixture("alert.json", alertMessage(alert, row).payload);
});
