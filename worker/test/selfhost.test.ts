import assert from "node:assert/strict";
import { test } from "node:test";
import { BUILT_IN_GUIDE, guideSource } from "../src/ai.ts";
import { pushMode, relayBody, relayOutcome, sendViaPager } from "../src/apns.ts";
import { deviceConfig } from "../src/config.ts";
import type { Env } from "../src/env.ts";
import { deviceSecretOf, isPairingRecord, normalizePairingCode, pairingKey, sha256Hex } from "../src/pairing.ts";
import { appManifest, newAppUrl } from "../src/setup.ts";

const env = (vars: Partial<Env>) => vars as Env;

test("a pairing code is eight Crockford characters, whatever the case, spaces or hyphens", () => {
  assert.equal(normalizePairingCode("7kq2-m9xa"), "7KQ2M9XA");
  assert.equal(normalizePairingCode(" 7KQ2 M9XA "), "7KQ2M9XA");
  assert.equal(normalizePairingCode("7KQ2M9XI"), null, "I is not in the alphabet");
  assert.equal(normalizePairingCode("7KQ2M9X"), null);
  assert.equal(normalizePairingCode(12345678), null);
  assert.equal(normalizePairingCode("7".repeat(33)), null);
});

test("a device secret is a bearer of 16 to 512 characters", () => {
  assert.equal(deviceSecretOf(`Bearer ${"a".repeat(16)}`), "a".repeat(16));
  assert.equal(deviceSecretOf(`Bearer ${"a".repeat(15)}`), null);
  assert.equal(deviceSecretOf(`Bearer ${"a".repeat(513)}`), null);
  assert.equal(deviceSecretOf(`Basic ${"a".repeat(16)}`), null);
  assert.equal(deviceSecretOf(null), null);
});

test("a fingerprint is the SHA-256 of the UTF-8 bytes, and a code's record is named by its hash", async () => {
  const hash = await sha256Hex("abc");
  assert.equal(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  assert.equal(pairingKey(hash), `pair/${hash}.json`);
});

test("only a well-formed record pairs", () => {
  const record = { role: "device", label: null, created_at: "2026-11-06T00:00:00Z", expires_at: "2026-11-06T00:30:00Z" };
  assert.ok(isPairingRecord(record));
  assert.ok(isPairingRecord({ ...record, role: "app", label: "iPad" }));
  assert.ok(!isPairingRecord({ ...record, role: "admin" }));
  assert.ok(!isPairingRecord({ ...record, expires_at: "soon" }));
  assert.ok(!isPairingRecord(null));
});

test("a Worker with only a GitHub token serves the PR list and nothing more", () => {
  assert.deepEqual(deviceConfig(env({ GITHUB_TOKEN: "t" }), "alex"), {
    features: { ask_ai: false, key_lines: false, rewrite: false, feedback: false, push: false, webhooks: false },
    login: "alex",
    limits: {
      pairing_attempts_per_ip_per_hour: 30, writes_per_minute: null, writes_per_hour: null, ask_questions_per_hour: null,
      ask_questions_per_day: null, ai_jobs_per_hour: null, ask_session_budget_cents: 200, github_reserve_percent: 10,
      github_reserve_minimum: 100, indexed_pull_requests_max: null, indexed_repos_max: 3_000,
      closed_pull_request_retention_days: null,
    },
  });
});

test("each feature follows what serves it", () => {
  const ask = { ASK_AGENT_ID: "a", ASK_ENVIRONMENT_ID: "e", ASK_VAULT_ID: "v", ASK_CREDENTIAL_ID: "c" };
  const selfHosted = deviceConfig(env({
    AI_ON_API_KEY: "on", ANTHROPIC_API_KEY: "k", ...ask, PUSH_RELAY_URL: "https://relay", PUSH_RELAY_KEY: "rks_x", GITHUB_ORGS: "acme, , beta",
  }), "alex");
  assert.deepEqual(selfHosted.features,
    { ask_ai: true, key_lines: true, rewrite: true, feedback: false, push: true, webhooks: false });
  assert.deepEqual(selfHosted.orgs, ["acme", "beta"]);
  const jai = deviceConfig(env({
    AI_ON_API_KEY: "on", ANTHROPIC_API_KEY: "k", ASK_ANTHROPIC_API_KEY: "k2", ...ask, FEEDBACK_REPO: "jai/agent-pager", HUB_TOKEN: "h",
    APNS_BUNDLE_ID: "b", APNS_KEY_ID: "i", APNS_TEAM_ID: "t", APNS_KEY_P8: "p", WEBHOOK_SECRET: "w",
  }), "jai");
  assert.deepEqual(jai.features, { ask_ai: true, key_lines: true, rewrite: true, feedback: true, push: true, webhooks: true });
  assert.equal("orgs" in jai, false);
  assert.equal(deviceConfig(env({ ...ask }), null).features.ask_ai, false, "Ask needs a key");
  assert.equal(deviceConfig(env({ AI_ON_API_KEY: "on", ANTHROPIC_API_KEY: " " }), null).features.key_lines, false, "a blank is unset");
  const keyAlone = deviceConfig(env({ ANTHROPIC_API_KEY: "k", ...ask }), null).features;
  assert.deepEqual([keyAlone.ask_ai, keyAlone.key_lines, keyAlone.rewrite], [false, false, false],
    "without AI_ON_API_KEY=on an API key turns no AI on");
});

test("push goes through the relay when it is set, else APNs with a whole key, else nowhere", () => {
  const apns = { APNS_BUNDLE_ID: "b", APNS_KEY_ID: "i", APNS_TEAM_ID: "t", APNS_KEY_P8: "p" };
  assert.equal(pushMode(env({ ...apns, PUSH_RELAY_URL: "https://relay", PUSH_RELAY_KEY: "rks_x" })), "relay");
  assert.equal(pushMode(env(apns)), "apns");
  assert.equal(pushMode(env({ ...apns, APNS_KEY_P8: "" })), "none");
  assert.equal(pushMode(env({ PUSH_RELAY_URL: "https://relay" })), "none");
});

test("the relay gets the same silent wake APNs would", () => {
  assert.deepEqual(relayBody("abcd", "production", 1_000), {
    device_token: "abcd", apns_env: "production", push_type: "background", priority: 5, collapse_id: "pr-sync",
    expiration: 2_800, payload: { aps: { "content-available": 1 }, reason: "pr_sync" },
  });
});

test("the relay's answer reads as APNs' own, and its refusals as reasons with no status", () => {
  assert.deepEqual(relayOutcome(200, { apns_status: 200, apns_id: "x", reason: null }), { status: 200, reason: null });
  assert.deepEqual(relayOutcome(200, { apns_status: 410, reason: "Unregistered" }), { status: 410, reason: "Unregistered" });
  assert.deepEqual(relayOutcome(200, { apns_status: null, reason: "apns_key_invalid" }),
    { status: null, reason: "apns_key_invalid" });
  assert.deepEqual(relayOutcome(200, "nonsense"), { status: null, reason: "relay_bad_response" });
  assert.deepEqual(relayOutcome(401, null), { status: null, reason: "relay_unauthorized" });
  assert.deepEqual(relayOutcome(429, null), { status: null, reason: "relay_rate_limited" });
  assert.deepEqual(relayOutcome(503, null), { status: null, reason: "relay_http_503" });
});

test("the webhook App is made on the org when one is named, else on the user, for this Worker's origin", () => {
  assert.equal(newAppUrl("acme", "s1"), "https://github.com/organizations/acme/settings/apps/new?state=s1");
  assert.equal(newAppUrl(undefined, "s1"), "https://github.com/settings/apps/new?state=s1");
  assert.equal(newAppUrl("", "s1"), "https://github.com/settings/apps/new?state=s1");
  const manifest = appManifest("https://pr.alex.workers.dev", "alex-pr-review") as Record<string, unknown>;
  assert.deepEqual(manifest.hook_attributes, { url: "https://pr.alex.workers.dev/github/webhook" });
  assert.equal(manifest.redirect_url, "https://pr.alex.workers.dev/github/callback");
});

test("the rewrite reads the guide named in GUIDE_REPO, else uses its own", () => {
  assert.deepEqual(guideSource({ GUIDE_REPO: "acme/agent-resources@main", GUIDE_FILES: "a.md, b/c.md" }),
    { repo: "acme/agent-resources", ref: "main", paths: ["a.md", "b/c.md"] });
  assert.deepEqual(guideSource({ GUIDE_REPO: "alex/docs", GUIDE_FILES: "pr.md" }), { repo: "alex/docs", ref: "", paths: ["pr.md"] });
  assert.equal(guideSource({}), null);
  assert.equal(guideSource({ GUIDE_REPO: "alex/docs" }), null, "a repo without files is no guide");
  assert.equal(guideSource({ GUIDE_REPO: "not a repo", GUIDE_FILES: "pr.md" }), null);
  assert.ok(BUILT_IN_GUIDE.length > 0);
});

test("Jai's instance hands every push to his Agent Pager Worker, over the relay and its own key", () => {
  const pager = { AGENT_PAGER_URL: "https://agent-pager.example", AGENT_PAGER_PUSH_TOKEN: "t".repeat(40) };
  const relay = { PUSH_RELAY_URL: "https://relay.example", PUSH_RELAY_KEY: "k" };
  const apns = { APNS_KEY_ID: "k", APNS_TEAM_ID: "t", APNS_KEY_P8: "p", APNS_BUNDLE_ID: "b" };
  assert.equal(pushMode(env({ ...pager, ...relay, ...apns })), "pager");
  assert.equal(pushMode(env({ AGENT_PAGER_URL: pager.AGENT_PAGER_URL, ...relay })), "relay");
});

test("a push to Agent Pager carries the message as it is, and its answer reads as the relay's", async () => {
  const sent: { url: string; init: RequestInit }[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    sent.push({ url, init });
    return Response.json({ apns_status: 200 });
  }) as typeof fetch;
  try {
    const outcome = await sendViaPager(
      env({ AGENT_PAGER_URL: "https://agent-pager.example/", AGENT_PAGER_PUSH_TOKEN: "secret" }),
      { pushType: "alert", priority: 10, collapseId: null, lifetimeSeconds: 60, payload: { aps: {}, reason: "pr_alert" } },
    );
    assert.deepEqual(outcome, { status: 200, reason: null });
    assert.equal(sent[0]?.url, "https://agent-pager.example/pr-push");
    assert.equal(new Headers(sent[0]?.init.headers).get("authorization"), "Bearer secret");
    assert.deepEqual(JSON.parse(String(sent[0]?.init.body)), {
      push_type: "alert", priority: 10, collapse_id: null, lifetime_seconds: 60, payload: { aps: {}, reason: "pr_alert" },
    });
  } finally {
    globalThis.fetch = realFetch;
  }
});
