// Checks-only GitHub request/response handling.
import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { readChecks } from "../../src/github.ts";
import { env, ref, stubGitHub } from "../support/read-cost-responses.ts";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

test("one PR GitHub refuses fails only its own part of a checks read", async () => {
  stubGitHub();
  const answered = globalThis.fetch;
  globalThis.fetch = (async (input: string, init?: RequestInit) => {
    const body = (await (await answered(input, init)).json()) as { data: Record<string, unknown> };
    return Response.json({
      data: { ...body.data, p1: null },
      errors: [{ type: "FORBIDDEN", path: ["p1"], message: "SAML enforcement" }],
    });
  }) as typeof fetch;
  const read = await readChecks([ref(7), ref(8), ref(9)], env);
  assert.equal(read.get(ref(8).id), "error");
  assert.equal(typeof read.get(ref(7).id), "object");
  assert.equal(typeof read.get(ref(9).id), "object");
});

test("a checks-only read of many PRs is one GraphQL query and no REST call", async () => {
  const calls = stubGitHub();
  const read = await readChecks([ref(7), ref(8), ref(9)], env);
  assert.equal(read.size, 3);
  const eight = read.get(ref(8).id);
  assert.equal(typeof eight === "object" ? eight?.mergeStateStatus : eight, "BLOCKED");
  assert.deepEqual(
    calls.map((call) => call.kind),
    ["graphql"],
  );
});
