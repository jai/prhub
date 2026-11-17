import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import {
  base64UrlOf,
  openToken,
  parseKeyring,
  pkceChallengeOf,
  randomToken,
  sealToken,
} from "../../src/token-crypto.ts";
const keyOf = (fill: number) => Buffer.alloc(32, fill).toString("base64");
const KEY = `k1:${keyOf(1)}`;

// --- Encryption -----------------------------------------------------------------------------------------------------

test("a sealed token opens with the same key and associated data, and its bytes are not the token's", async () => {
  const keyring = await parseKeyring(KEY);
  assert.ok(keyring);
  const sealed = await sealToken(keyring, "ghu_secret", "prhub:user:1:access");
  assert.match(sealed, /^v1\.k1\.[\w-]{16}\.[\w-]+$/);
  assert.equal(sealed.includes("ghu_secret"), false);
  assert.deepEqual(await openToken(keyring, sealed, "prhub:user:1:access"), {
    plaintext: "ghu_secret",
    isStale: false,
  });
  assert.notEqual(
    await sealToken(keyring, "ghu_secret", "prhub:user:1:access"),
    sealed,
    "a new IV every time",
  );
});

test("a changed byte, another person's or field's data, or an unknown key opens nothing", async () => {
  const keyring = await parseKeyring(KEY);
  assert.ok(keyring);
  const sealed = await sealToken(keyring, "ghu_secret", "prhub:user:1:access");
  const [version, id, iv, body] = sealed.split(".");
  const bytes = Buffer.from(body, "base64url");
  bytes[0] ^= 1;
  const tampered = [version, id, iv, base64UrlOf(new Uint8Array(bytes))].join(".");
  assert.equal(await openToken(keyring, tampered, "prhub:user:1:access"), null);
  assert.equal(await openToken(keyring, sealed, "prhub:user:2:access"), null, "another person");
  assert.equal(await openToken(keyring, sealed, "prhub:user:1:refresh"), null, "another field");
  const other = await parseKeyring(`k2:${keyOf(2)}`);
  assert.ok(other);
  assert.equal(
    await openToken(other, sealed, "prhub:user:1:access"),
    null,
    "a key it was not sealed with",
  );
  assert.equal(await openToken(keyring, "v2.k1.x.y", "prhub:user:1:access"), null);
  assert.equal(await openToken(keyring, `${sealed}.extra`, "prhub:user:1:access"), null);
});

test("a rotated keyring seals with its first key and still opens what an older key sealed", async () => {
  const old = await parseKeyring(KEY);
  const rotated = await parseKeyring(`k2:${keyOf(2)}, ${KEY}`);
  assert.ok(old && rotated);
  const sealed = await sealToken(old, "ghu_secret", "a");
  assert.deepEqual(await openToken(rotated, sealed, "a"), {
    plaintext: "ghu_secret",
    isStale: true,
  });
  assert.match(await sealToken(rotated, "ghu_secret", "a"), /^v1\.k2\./);
});

test("a keyring entry must be an id and 32 bytes, with no id twice", async () => {
  assert.equal(await parseKeyring(undefined), null);
  assert.equal(await parseKeyring(keyOf(1)), null, "no id");
  assert.equal(await parseKeyring(`k1:${Buffer.alloc(16).toString("base64")}`), null, "16 bytes");
  assert.equal(await parseKeyring(`k1:${keyOf(1)},k1:${keyOf(2)}`), null, "the same id twice");
  assert.equal(await parseKeyring("bad id:xyz"), null);
});

test("PKCE S256 is base64url of the verifier's SHA-256, unpadded", async () => {
  const verifier = randomToken();
  assert.equal(
    await pkceChallengeOf(verifier),
    createHash("sha256").update(verifier).digest("base64url"),
  );
  assert.equal(randomToken().length, 43);
});
