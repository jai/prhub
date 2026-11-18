import assert from "node:assert/strict";
import { test } from "node:test";
import { checkLinearKey } from "../../src/tickets.ts";

const key = "lin_api_synthetic012345678901234567890";

test("Linear GraphQL rejection and transport failures do not become a connected account", async () => {
  assert.equal(
    await checkLinearKey(key, async () =>
      Response.json({ errors: [{ message: "Authentication required" }] }),
    ),
    "invalid",
  );
  assert.equal(
    await checkLinearKey(key, async () => {
      throw new Error("offline");
    }),
    "unavailable",
  );
});
