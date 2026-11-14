// A PR's screen says what it cost GitHub, so the apps' share of the token's hour can be measured.
import assert from "node:assert/strict";
import test from "node:test";
import type { Env } from "../src/env.ts";
import { counted } from "../src/github-calls.ts";

test("a counted read carries its GitHub calls as Server-Timing, and its own headers too", async () => {
  const response = await counted({} as Env, async (env) => {
    env.GITHUB_CALLS!.count += 2;
    return new Response("{}", { headers: { "Content-Type": "application/json" } });
  });
  assert.equal(response.headers.get("Server-Timing"), 'github;desc="github calls";dur=2');
  assert.equal(response.headers.get("Content-Type"), "application/json");
});
