import assert from "node:assert/strict";
import { test } from "node:test";
import { deviceConfig } from "../../src/config.ts";
import { scopedKey, type Env } from "../../src/env.ts";
import { hostedMode, userEnv } from "../../src/hosted.ts";

const env = (vars: Partial<Env>) => vars as Env;
const complete = env({
  HOSTED: "on",
  GITHUB_APP_CLIENT_ID: "id",
  GITHUB_APP_CLIENT_SECRET: "secret",
  TOKEN_ENCRYPTION_KEY: "key",
  USER_ACCOUNTS: {} as Env["USER_ACCOUNTS"],
  SIGN_INS: {} as Env["SIGN_INS"],
  INSTALLATIONS: {} as Env["INSTALLATIONS"],
  IP_LIMITS: {} as Env["IP_LIMITS"],
});

test("hosted mode is off unless HOSTED is on, and serves nothing when it is on but incomplete", () => {
  assert.deepEqual(hostedMode(env({ GITHUB_TOKEN: "t" })), { kind: "off" });
  assert.deepEqual(hostedMode(env({ GITHUB_TOKEN: "t", GITHUB_APP_CLIENT_ID: "x", HOSTED: "" })), {
    kind: "off",
  });
  assert.deepEqual(hostedMode(env({ HOSTED: "on", GITHUB_APP_CLIENT_ID: "x" })), {
    kind: "misconfigured",
    missing: [
      "GITHUB_APP_CLIENT_SECRET",
      "TOKEN_ENCRYPTION_KEY",
      "USER_ACCOUNTS",
      "SIGN_INS",
      "INSTALLATIONS",
      "IP_LIMITS",
    ],
  });
  assert.equal(hostedMode(complete).kind, "on");
});

test("a person's env acts with their token, under their own objects and R2 prefix, with AI off", () => {
  const base = env({
    GITHUB_TOKEN: "unused",
    ANTHROPIC_API_KEY: "sk-test",
    ASK_AGENT_ID: "a",
    ASK_ENVIRONMENT_ID: "e",
    ASK_VAULT_ID: "v",
    ASK_CREDENTIAL_ID: "c",
    ASK_ANTHROPIC_API_KEY: "k",
    WEBHOOK_SECRET: "w",
    APP_TOKEN: "jai",
  });
  const person = userEnv(base, { userId: "4242", login: "octocat", token: "ghu_x" });
  assert.equal(person.GITHUB_TOKEN, "ghu_x");
  assert.equal(person.APP_TOKEN, undefined);
  assert.equal(scopedKey(person, "o/r/1/abc.diff"), "users/4242/o/r/1/abc.diff");
  assert.equal(
    scopedKey(base, "o/r/1/abc.diff"),
    "o/r/1/abc.diff",
    "a self-hosted Worker's keys are as they were",
  );
  assert.deepEqual(deviceConfig(person, "octocat").features, {
    ask_ai: false,
    key_lines: false,
    rewrite: false,
    feedback: false,
    push: false,
    webhooks: false,
  });
});

test("only a login in SUBSCRIPTION_LOGINS runs AI on the Worker's subscription", () => {
  const base = env({
    CLAUDE_CODE_OAUTH_TOKEN: "oat-test",
    SUBSCRIPTION_LOGINS: " OctoCat ,hubot",
    AGENT: {} as Env["AGENT"],
  });
  const listed = userEnv(base, { userId: "4242", login: "octocat", token: "ghu_x" });
  assert.equal(listed.CLAUDE_CODE_OAUTH_TOKEN, "oat-test");
  assert.equal(deviceConfig(listed, "octocat").features.key_lines, true);
  const other = userEnv(base, { userId: "5151", login: "mona", token: "ghu_y" });
  assert.equal(other.CLAUDE_CODE_OAUTH_TOKEN, undefined);
  assert.equal(deviceConfig(other, "mona").features.key_lines, false);
});
