import { env, exports } from "cloudflare:workers";
import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { expect, test } from "vitest";
import type { PendingSignIn } from "../../../src/hosted.ts";
import { LimitName, limitsOf, rateWindowOf } from "../../../src/limits.ts";
import { question } from "../../support/ask-queue-values.ts";
import { authorization } from "./values.ts";

test("the real PR index initializes its schema and keeps write receipts across eviction", async () => {
  const index = env.PR_INDEX.getByName("write-receipts");
  const now = Date.now();
  expect(await index.rows()).toEqual({ prs: [], synced_at: 0 });
  expect(await index.claimWrite("request-1", now)).toBe("go");
  expect(await index.claimWrite("request-1", now)).toBe("busy");
  await index.finishWrite("request-1", true, now);
  await evictDurableObject(index);
  expect(await index.claimWrite("request-1", now)).toBe("done");
  expect(await env.PR_INDEX.getByName("another-person").claimWrite("request-1", now)).toBe("go");
});

test("authenticated HTTP routes persist device events through the real PR index binding", async () => {
  const refused = await exports.default.fetch("https://prhub.test/device/event", {
    method: "POST",
    body: JSON.stringify({ kind: "runtime-test", marker: "must-not-land" }),
  });
  expect(refused.status).toBe(401);
  const accepted = await exports.default.fetch("https://prhub.test/device/event", {
    method: "POST",
    headers: authorization,
    body: JSON.stringify({ kind: "runtime-test", marker: "stored-through-route" }),
  });
  expect(accepted.status).toBe(204);
  await evictDurableObject(env.PR_INDEX.getByName("runtime-test"));
  const response = await exports.default.fetch("https://prhub.test/events", {
    headers: authorization,
  });
  expect(response.status).toBe(200);
  const events = await response.json<{ kind: string; detail: string }[]>();
  expect(
    events
      .filter((event) => event.kind === "runtime-test")
      .map((event) => JSON.parse(event.detail)),
  ).toEqual([{ marker: "stored-through-route" }]);
});

test("a sign-in survives eviction, is consumed once, and its expiry alarm removes it", async () => {
  const signIn = env.SIGN_INS!.getByName("pending-sign-in");
  const pending: PendingSignIn = {
    app_state: "app-state",
    app_challenge: "challenge",
    github_verifier: "verifier",
    redirect_uri: "https://prhub.test/auth/github/done",
    expires_at: Date.now() + 60_000,
  };
  await signIn.begin(pending);
  await evictDurableObject(signIn);
  expect(await signIn.take()).toEqual(pending);
  expect(await signIn.take()).toBeNull();
  expect(await runInDurableObject(signIn, (_, state) => state.storage.getAlarm())).toBeNull();
  await signIn.begin(pending);
  expect(await runInDurableObject(signIn, (_, state) => state.storage.getAlarm())).toBe(
    pending.expires_at,
  );
  expect(await runDurableObjectAlarm(signIn)).toBe(true);
  expect(await signIn.take()).toBeNull();
});

test("an IP limit's alarm clears expired storage and leaves the object able to count again", async () => {
  const limits = limitsOf({ LIMIT_PAIRING_ATTEMPTS_PER_IP_PER_HOUR: "1" });
  const window = rateWindowOf(limits, LimitName.PairingAttemptsPerIpPerHour);
  expect(window).not.toBeNull();
  const checks = [{ name: LimitName.PairingAttemptsPerIpPerHour, window: window! }];
  const counter = env.IP_LIMITS!.getByName("ip-limit");
  const now = Date.now();
  expect(await counter.consume(checks, "first", now)).toEqual({ allowed: true });
  expect((await counter.consume(checks, "second", now)).allowed).toBe(false);
  expect(await runInDurableObject(counter, (_, state) => state.storage.getAlarm())).toBe(
    now + window!.windowMs,
  );
  expect(await runDurableObjectAlarm(counter)).toBe(true);
  expect(
    await runInDurableObject(counter, (_, state) =>
      state.storage.sql.exec("SELECT * FROM limit_hits").toArray(),
    ),
  ).toEqual([]);
  expect(await counter.consume(checks, "after-expiry", now + window!.windowMs)).toEqual({
    allowed: true,
  });
});

test("a question queued in the real ask queue ends a held read's wait on its PR", async () => {
  const pr = "acme/api#7";
  const queue = env.AI_JOBS.get(env.AI_JOBS.idFromName("held-ask"));
  const { version, activity } = await queue.askNow(pr);
  expect(activity).toBeNull();
  const waited = queue.awaitAsk(pr, version, 30_000);
  await queue.queueAsk(question("held", "Is it tested?"), pr, null);
  await waited;
  expect((await queue.askNow(pr)).version).not.toBe(version);
  await runInDurableObject(queue, (_object, state) => state.storage.deleteAlarm());
});
