import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { test } from "vitest";
import { installationToken, TOKEN_MARGIN_MS } from "../../src/read-app.ts";

const { privateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

const HOUR = 3_600_000;

test("a token is minted once and kept until five minutes before it expires", async () => {
  const app = { id: "app-cache", key: privateKey };
  let mints = 0;
  const expiresAt = Date.parse("2026-11-16T10:00:00Z");
  const fetcher = (async () => {
    mints += 1;
    return Response.json({ token: `t${mints}`, expires_at: new Date(expiresAt).toISOString() });
  }) as typeof fetch;
  const early = expiresAt - HOUR;
  const [first, second] = await Promise.all([
    installationToken(app, 11, fetcher, early),
    installationToken(app, 11, fetcher, early),
  ]);
  assert.deepEqual([first, second, mints], ["t1", "t1", 1]);
  assert.equal(await installationToken(app, 11, fetcher, expiresAt - TOKEN_MARGIN_MS - 1), "t1");
  assert.equal(await installationToken(app, 11, fetcher, expiresAt - TOKEN_MARGIN_MS + 1), "t2");
  assert.equal(
    await installationToken(app, 12, fetcher, early),
    "t3",
    "each installation has its own",
  );
});

test("a refused mint is not kept: the next read asks again", async () => {
  const app = { id: "app-refused", key: privateKey };
  const now = Date.parse("2026-11-16T09:00:00Z");
  let mints = 0;
  const fetcher = (async () => {
    mints += 1;
    return mints === 1
      ? new Response(null, { status: 403 })
      : Response.json({ token: "t", expires_at: new Date(now + HOUR).toISOString() });
  }) as typeof fetch;
  await assert.rejects(installationToken(app, 11, fetcher, now));
  assert.equal(await installationToken(app, 11, fetcher, now), "t");
});
