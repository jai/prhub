// A diff the index stored in R2 is what the phone reads: the real bucket binding, through the Worker's own route.
import { env, exports } from "cloudflare:workers";
import { expect, test } from "vitest";
import { authorization } from "./values.ts";

test("a diff kept in the real R2 bucket is served through the Worker's route without asking GitHub", async () => {
  const revision = `${"a".repeat(40)}-main`;
  await env.DIFFS.put(`acme/app/7/${revision}.diff`, "diff --git a/x b/x\n");
  const response = await exports.default.fetch(
    `https://prhub.test/prs/acme/app/7/diff?revision=${revision}`,
    { headers: authorization },
  );
  expect(response.status).toBe(200);
  expect(await response.text()).toBe("diff --git a/x b/x\n");
  expect(response.headers.get("Server-Timing")).toBe('github;desc="github calls";dur=0');
});
