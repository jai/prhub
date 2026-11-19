// Webhook deliveries routed by installation (`installation-core.ts`) to each member's index, over the in-memory hosted
// world: only to people who see the repo, with their own involvement, and nothing once a repo or installation goes.
import assert from "node:assert/strict";
import { test } from "vitest";
import { authenticate } from "../../src/hosted.ts";
import {
  ALICE,
  BOB,
  bearer,
  deliver,
  type FakeUser,
  ORIGIN,
  twoOrgs,
  type World,
} from "../support/hosted-world.ts";

const SHA = "a".repeat(40);

const pullRequest = (installation: number, name: string, extra: object = {}) => ({
  action: "synchronize",
  installation: { id: installation },
  sender: { id: 9 },
  repository: { full_name: name },
  pull_request: { number: 7, user: { login: "someone" }, requested_reviewers: [] },
  ...extra,
});

const marks = (world: World, user: FakeUser) => world.indexes.get(String(user.id))?.marks() ?? [];

async function runChecks(world: World): Promise<void> {
  for (const installation of world.installations.values()) {
    await installation.runChecks(world.clock.now);
  }
}

test("sign-in joins each installation the person's own token reaches, with the repos it can see there", async () => {
  const { world } = await twoOrgs();
  assert.deepEqual(
    [...((await world.installations.get("11")?.members()) ?? new Map()).keys()],
    ["1001"],
  );
  assert.deepEqual(
    [...((await world.installations.get("22")?.members()) ?? new Map()).keys()],
    ["2002"],
  );
  assert.deepEqual(
    [...((await world.installations.get("33")?.members()) ?? new Map()).keys()].sort(),
    ["1001", "2002"],
  );
  assert.deepEqual(await world.accounts.get("1001")?.installationIds(), ["11", "33"]);
  const listed = world.github.calls.filter((call) => call.url.includes("/user/installations"));
  assert.ok(
    listed.every((call) => /^Bearer ghu_\d+$/.test(call.headers.get("Authorization") ?? "")),
    "only user tokens read who sees what",
  );
});

test("a delivery for a repo only Alice can see reaches only Alice's index", async () => {
  const { world } = await twoOrgs();
  assert.equal((await deliver(world, "pull_request", pullRequest(11, "acme/api"))).status, 202);
  assert.deepEqual(marks(world, ALICE), ["mark:acme/api#7:false"]);
  assert.deepEqual(marks(world, BOB), []);
});

test("in a shared org each person gets only the repos they see, with their own involvement", async () => {
  const { world } = await twoOrgs();
  await deliver(world, "pull_request", pullRequest(33, "initech/private"));
  await deliver(
    world,
    "pull_request",
    pullRequest(33, "initech/shared", {
      action: "review_requested",
      requested_reviewer: { login: "bob" },
    }),
  );
  assert.deepEqual(marks(world, ALICE), [
    "mark:initech/private#7:false",
    "mark:initech/shared#7:false",
  ]);
  assert.deepEqual(marks(world, BOB), ["mark:initech/shared#7:true"]);
});

test("a repo in the installation the person cannot see is checked with their token once, and never delivered", async () => {
  const { world } = await twoOrgs();
  await deliver(world, "pull_request", pullRequest(11, "acme/secret"));
  assert.deepEqual(marks(world, ALICE), [], "in doubt: nothing until her token answers");
  await runChecks(world);
  assert.deepEqual(marks(world, ALICE), []);
  const asked = world.github.calls.filter(
    (call) => call.url === "https://api.github.com/repos/acme/secret",
  );
  assert.equal(asked.length, 1);
  assert.match(
    asked[0].headers.get("Authorization") ?? "",
    /^Bearer ghu_/,
    "asked with Alice's own token",
  );
  await deliver(world, "pull_request", pullRequest(11, "acme/secret"));
  await runChecks(world);
  assert.equal(
    world.github.calls.filter((call) => call.url.endsWith("/repos/acme/secret")).length,
    1,
    "the no is kept",
  );
  assert.deepEqual(marks(world, BOB), []);
});

test("a repo added to an installation reaches a member after their token says they see it", async () => {
  const { world } = await twoOrgs();
  world.github.installations.get(11)?.repos.push("acme/new");
  world.github.grant(ALICE, ["acme/new"]);
  world.clock.now += 1_000;
  await deliver(world, "installation_repositories", {
    action: "added",
    installation: { id: 11 },
    sender: { id: 9 },
    repositories_added: [{ full_name: "acme/new" }],
    repositories_removed: [],
  });
  await deliver(world, "pull_request", pullRequest(11, "acme/new"));
  assert.deepEqual(marks(world, ALICE), []);
  await runChecks(world);
  assert.deepEqual(marks(world, ALICE), ["mark:acme/new#7:false"]);
  await deliver(world, "pull_request", pullRequest(11, "acme/new"));
  assert.deepEqual(
    marks(world, ALICE),
    ["mark:acme/new#7:false", "mark:acme/new#7:false"],
    "known now: no second ask",
  );
});

const drops = (world: World, user: FakeUser) =>
  world.indexes.get(String(user.id))?.calls.filter((call) => call.startsWith("drop:")) ?? [];

test("a removed repo, a suspended or a deleted installation routes nothing, and drops its rows at once", async () => {
  const { world } = await twoOrgs();
  world.github.installations.set(11, { account: "acme", repos: ["acme/secret"] });
  await deliver(world, "installation_repositories", {
    action: "removed",
    installation: { id: 11 },
    sender: { id: 9 },
    repositories_added: [],
    repositories_removed: [{ full_name: "acme/api" }],
  });
  await deliver(world, "pull_request", pullRequest(11, "acme/api"));
  await runChecks(world);
  assert.deepEqual(marks(world, ALICE), []);
  assert.deepEqual(drops(world, ALICE), ["drop:acme/api"]);
  assert.deepEqual(drops(world, BOB), [], "Bob is no member of acme");

  await deliver(world, "installation", {
    action: "suspend",
    installation: { id: 33, account: { login: "initech" } },
  });
  await deliver(world, "pull_request", pullRequest(33, "initech/shared"));
  assert.deepEqual([...marks(world, ALICE), ...marks(world, BOB)], []);
  assert.deepEqual(drops(world, ALICE).at(-1), "drop:initech/private,initech/shared");
  assert.deepEqual(drops(world, BOB), ["drop:initech/private,initech/shared"]);
  await deliver(world, "installation", {
    action: "unsuspend",
    installation: { id: 33, account: { login: "initech" } },
  });
  await deliver(world, "pull_request", pullRequest(33, "initech/shared"));
  assert.equal([...marks(world, ALICE), ...marks(world, BOB)].length, 2);

  await deliver(world, "installation", {
    action: "deleted",
    installation: { id: 22, account: { login: "globex" } },
  });
  await deliver(world, "pull_request", pullRequest(22, "globex/web"));
  await runChecks(world);
  assert.deepEqual(marks(world, BOB), ["mark:initech/shared#7:false"]);
  assert.deepEqual(drops(world, BOB).at(-1), "drop:globex/web");
});

test("check suites and statuses mark the PRs at their head, for members who see the repo", async () => {
  const { world } = await twoOrgs();
  await deliver(world, "check_suite", {
    action: "completed",
    installation: { id: 33 },
    repository: { full_name: "initech/private" },
    check_suite: { head_sha: SHA, pull_requests: [] },
  });
  await deliver(world, "status", {
    installation: { id: 33 },
    repository: { full_name: "initech/shared" },
    sha: SHA,
    state: "success",
  });
  assert.deepEqual(marks(world, ALICE), [
    "head:initech/private@aaaaaaa",
    "head:initech/shared@aaaaaaa",
  ]);
  assert.deepEqual(marks(world, BOB), ["head:initech/shared@aaaaaaa"]);
});

test("a delivery with the wrong signature or no installation touches nobody", async () => {
  const { world } = await twoOrgs();
  assert.equal(
    (await deliver(world, "pull_request", pullRequest(11, "acme/api"), "not the secret")).status,
    401,
  );
  const { installation: _, ...withoutInstallation } = pullRequest(11, "acme/api");
  assert.equal((await deliver(world, "pull_request", withoutInstallation)).status, 202);
  assert.deepEqual([...marks(world, ALICE), ...marks(world, BOB)], []);
});

test("deleting Alice takes her out of every installation and leaves Bob as he was", async () => {
  const { world, alice, bob } = await twoOrgs();
  const answer = await world.route("/account", { method: "DELETE", ...bearer(alice) });
  assert.equal(answer.status, 200);
  assert.deepEqual(
    [...((await world.installations.get("33")?.members()) ?? new Map()).keys()],
    ["2002"],
  );
  assert.equal((await world.installations.get("11")?.members())?.size, 0);
  const aliceIndex = world.indexes.get("1001");
  const before = aliceIndex?.calls.length;
  await deliver(world, "pull_request", pullRequest(33, "initech/shared"));
  await deliver(world, "pull_request", pullRequest(33, "initech/private"));
  await deliver(world, "pull_request", pullRequest(11, "acme/api"));
  await runChecks(world);
  assert.equal(
    aliceIndex?.calls.length,
    before,
    "no delivery reaches, or makes again, a deleted index",
  );
  assert.deepEqual(marks(world, BOB), ["mark:initech/shared#7:false"]);
  assert.deepEqual(world.deleted, ["1001"], "only Alice's R2 prefix");
  assert.deepEqual(
    world.forgottenJobs,
    ["1001"],
    "no queued AI job of hers runs, or stores an answer, after",
  );
  assert.equal(world.stores.get("1001")?.map.size, 0, "her account holds nothing");
  for (const store of world.installationStores.values()) {
    assert.deepEqual(
      [...store.map.keys()].filter((key) => key.includes("1001")),
      [],
      "no installation names her",
    );
  }
  const auth = await authenticate(
    new Request(`${ORIGIN}/prs`, bearer(bob)),
    world.workerEnv,
    world.services,
  );
  assert.ok("env" in auth && auth.env.GITHUB_LOGIN === "bob");
  assert.ok(world.stores.get("2002")?.map.has("account"));
});
