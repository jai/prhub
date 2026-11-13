import assert from "node:assert/strict";
import { test } from "node:test";
import { chatOf } from "../src/ask-chat.ts";
import { deviceConfig } from "../src/config.ts";
import type { Env } from "../src/env.ts";
import {
  aiKey, BUILT_IN_DEFAULTS, costCents, effortsFor, featureModels, parseAiConfig, resolveChoice, SUPPORTED_MODELS,
} from "../src/models.ts";

const head = "504754b2bc3ce5db892dde980e4bc83b60ff7a68";
const variables = (config: ReturnType<typeof parseAiConfig>) => config.problems.map((problem) => problem.variable);

test("unset vars: every supported model, up to high, and today's models and efforts", () => {
  const config = parseAiConfig({});
  assert.deepEqual(config.allowed, [...SUPPORTED_MODELS]);
  assert.equal(config.effortMax, "high");
  assert.deepEqual(config.defaults, {
    key_lines: { model: "claude-sonnet-5-5", effort: "high" },
    rewrite: { model: "claude-sonnet-5-5", effort: "high" },
    ask: { model: "claude-opus-5-5", effort: "medium" },
  });
  assert.deepEqual(config.problems, []);
  assert.deepEqual(parseAiConfig({ AI_MODELS_ALLOWED: " ", AI_EFFORT_MAX: "", AI_DEFAULTS: "" }), config, "blank is unset");
});

test("the allowed list is intersected with what the code supports, and Fable never gets in", () => {
  const config = parseAiConfig({ AI_MODELS_ALLOWED: "claude-opus-5-5, claude-fable-5-1,claude-haiku-5-5" });
  assert.deepEqual(config.allowed, ["claude-haiku-5-5", "claude-opus-5-5"], "in the code's order");
  assert.deepEqual(config.problems, [
    { variable: "AI_MODELS_ALLOWED", value: "claude-fable-5-1", reason: "not a model this code supports" },
  ]);
  const none = parseAiConfig({ AI_MODELS_ALLOWED: "claude-fable-5-1" });
  assert.deepEqual(none.allowed, [...SUPPORTED_MODELS], "nothing usable falls back to all supported");
  assert.deepEqual(variables(none), ["AI_MODELS_ALLOWED", "AI_MODELS_ALLOWED"]);
});

test("the effort cap is low, medium or high; anything else, xhigh and max included, is high", () => {
  assert.equal(parseAiConfig({ AI_EFFORT_MAX: "medium" }).effortMax, "medium");
  for (const value of ["xhigh", "max", "HIGH", "fast"]) {
    const config = parseAiConfig({ AI_EFFORT_MAX: value });
    assert.equal(config.effortMax, "high", value);
    assert.deepEqual(variables(config), ["AI_EFFORT_MAX"], value);
  }
  assert.deepEqual(effortsFor({ effortMax: "medium" }, "claude-opus-5-5"), ["low", "medium"]);
});

test("defaults read as a feature=model:effort list or JSON, and a model alone takes its own default effort", () => {
  const listed = parseAiConfig({ AI_DEFAULTS: "key_lines=claude-haiku-5-5:low; rewrite=claude-opus-5-5" });
  assert.deepEqual(listed.defaults.key_lines, { model: "claude-haiku-5-5", effort: "low" });
  assert.deepEqual(listed.defaults.rewrite, { model: "claude-opus-5-5", effort: "medium" });
  assert.deepEqual(listed.defaults.ask, BUILT_IN_DEFAULTS.ask);
  assert.deepEqual(listed.problems, []);
  const json = parseAiConfig({
    AI_DEFAULTS: '{"ask": {"model": "claude-sonnet-5-5", "effort": "low"}, "key_lines": "claude-opus-5-5:high"}',
  });
  assert.deepEqual(json.defaults.ask, { model: "claude-sonnet-5-5", effort: "low" });
  assert.deepEqual(json.defaults.key_lines, { model: "claude-opus-5-5", effort: "high" });
});

test("a bad default is reported and the built-in one serves", () => {
  const config = parseAiConfig({
    AI_DEFAULTS: "key_lines=claude-fable-5-1:high,rewrite=claude-opus-5-5:max,chat=claude-opus-5-5,ask=claude-opus-5-5:a:b",
  });
  assert.deepEqual(config.defaults, BUILT_IN_DEFAULTS);
  assert.equal(config.problems.length, 4);
  assert.ok(config.problems.every((problem) => problem.variable === "AI_DEFAULTS"));
  assert.deepEqual(variables(parseAiConfig({ AI_DEFAULTS: "{not json" })), ["AI_DEFAULTS"]);
  assert.deepEqual(parseAiConfig({ AI_DEFAULTS: "{not json" }).defaults, BUILT_IN_DEFAULTS);
});

test("a default the config can't serve is clamped: lower effort, else an allowed model", () => {
  const capped = parseAiConfig({ AI_EFFORT_MAX: "medium", AI_DEFAULTS: "ask=claude-opus-5-5:high" });
  assert.deepEqual(capped.defaults.ask, { model: "claude-opus-5-5", effort: "medium" });
  assert.deepEqual(capped.defaults.key_lines, { model: "claude-sonnet-5-5", effort: "medium" }, "built-ins clamp too");
  assert.deepEqual(variables(capped), ["AI_DEFAULTS"], "only the default someone set is a problem");
  const narrowed = parseAiConfig({ AI_MODELS_ALLOWED: "claude-haiku-5-5" });
  assert.deepEqual(narrowed.defaults.ask, { model: "claude-haiku-5-5", effort: "medium" });
  assert.deepEqual(narrowed.problems, [], "a built-in default outside a valid allowed list is not a config error");
  const pinned = parseAiConfig({ AI_MODELS_ALLOWED: "claude-haiku-5-5", AI_DEFAULTS: "ask=claude-opus-5-5:low" });
  assert.deepEqual(pinned.defaults.ask, { model: "claude-haiku-5-5", effort: "medium" });
  assert.equal(pinned.problems.length, 1);
});

test("a request picks within the allowed list and the cap, or gets the feature's default", () => {
  const config = parseAiConfig({ AI_MODELS_ALLOWED: "claude-haiku-5-5,claude-sonnet-5-5", AI_EFFORT_MAX: "medium" });
  assert.deepEqual(resolveChoice(config, "key_lines", {}),
    { ok: true, choice: { model: "claude-sonnet-5-5", effort: "medium" } });
  assert.deepEqual(resolveChoice(config, "key_lines", { model: "claude-haiku-5-5" }),
    { ok: true, choice: { model: "claude-haiku-5-5", effort: "medium" } });
  assert.deepEqual(resolveChoice(config, "rewrite", { effort: "low" }),
    { ok: true, choice: { model: "claude-sonnet-5-5", effort: "low" } });
  const fullCap = parseAiConfig({});
  assert.deepEqual(resolveChoice(fullCap, "key_lines", { model: "claude-opus-5-5" }),
    { ok: true, choice: { model: "claude-opus-5-5", effort: "medium" } }, "another model: its own default effort");
  for (const requested of [
    { model: "claude-opus-5-5" }, { model: "claude-fable-5-1" }, { model: 3 }, { effort: "high" }, { effort: "max" },
    { model: "claude-haiku-5-5", effort: "xhigh" },
  ]) {
    const result = resolveChoice(config, "ask", requested);
    assert.equal(result.ok, false, JSON.stringify(requested));
  }
  const refused = resolveChoice(config, "ask", { effort: "high" });
  assert.ok(!refused.ok && refused.error === "effort must be one of low, medium for claude-haiku-5-5", "Ask falls to the first allowed model");
});

test("each model and effort has its own cache key, and the built-in default has one key", () => {
  const job = { kind: "key_lines" as const, repo: "a/b", number: 7, head, context: 100 };
  const legacy = `ai/a/b/7/${head}/key-lines-v2-100.json`;
  assert.equal(aiKey(job), legacy, "a job queued before the choice existed");
  assert.equal(aiKey({ ...job, choice: BUILT_IN_DEFAULTS.key_lines }), legacy);
  const haiku = aiKey({ ...job, choice: { model: "claude-haiku-5-5", effort: "low" } });
  const haikuMedium = aiKey({ ...job, choice: { model: "claude-haiku-5-5", effort: "medium" } });
  assert.equal(haiku, `ai/a/b/7/${head}/key-lines-v2-100-claude-haiku-5-5-low.json`);
  assert.notEqual(haiku, haikuMedium);
  assert.equal(aiKey({ ...job, kind: "rewrite", choice: BUILT_IN_DEFAULTS.rewrite }), `ai/a/b/7/${head}/rewrite.json`);
  assert.equal(aiKey({ ...job, kind: "rewrite", choice: { model: "claude-sonnet-5-5", effort: "low" } }),
    `ai/a/b/7/${head}/rewrite-claude-sonnet-5-5-low.json`);
});

test("cost is list price in cents, Haiku's long-prompt rate included, and null for a model with no price", () => {
  assert.equal(costCents("claude-sonnet-5-5", { input: 10_000, output: 1_000 }), 3);
  assert.equal(costCents("claude-opus-5-5", { input: 1_000_000, output: 0 }), 400);
  assert.equal(costCents("claude-haiku-5-5", { input: 100_000, output: 10_000 }), 1.5);
  assert.equal(costCents("claude-haiku-5-5", { input: 200_000, output: 10_000 }), 12.5);
  assert.equal(costCents("claude-opus-4-8", { input: 1, output: 1 }), null);
});

test("/device/config lists models only for the AI features that are on", () => {
  const env = (vars: Partial<Env>) => vars as Env;
  assert.equal("ai" in deviceConfig(env({ GITHUB_TOKEN: "t" }), "alex"), false);
  const keyOnly = deviceConfig(env({ AI_ON_API_KEY: "on", ANTHROPIC_API_KEY: "k", AI_MODELS_ALLOWED: "claude-sonnet-5-5,claude-opus-5-5",
    AI_EFFORT_MAX: "medium" }), "alex");
  assert.deepEqual(Object.keys(keyOnly.ai!.features), ["key_lines", "rewrite"]);
  assert.deepEqual(keyOnly.ai!.features.key_lines, {
    default: { model: "claude-sonnet-5-5", effort: "medium" },
    allowed: [
      { model: "claude-sonnet-5-5", label: "Sonnet 5.5", efforts: ["low", "medium"] },
      { model: "claude-opus-5-5", label: "Opus 5.5", efforts: ["low", "medium"] },
    ],
  });
  const ask = { ASK_AGENT_ID: "a", ASK_ENVIRONMENT_ID: "e", ASK_VAULT_ID: "v", ASK_CREDENTIAL_ID: "c" };
  const all = deviceConfig(env({ AI_ON_API_KEY: "on", ANTHROPIC_API_KEY: "k", ...ask }), "alex");
  assert.deepEqual(all.ai!.features.ask, featureModels(parseAiConfig({}), "ask"));
});

test("an Ask chat says which model and effort its session runs at", () => {
  const chat = chatOf([], 12, undefined, { model: "claude-opus-5-5", effort: "medium" });
  assert.equal(chat.model, "claude-opus-5-5");
  assert.equal(chat.effort, "medium");
  assert.equal(chat.costCents, 12);
  assert.equal(chatOf([], null).model, null);
});
