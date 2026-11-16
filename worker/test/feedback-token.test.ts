import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { deviceConfig } from "../src/config.ts";
import { feedbackDirectURL, feedbackTokenRoute, signFeedbackToken } from "../src/feedback-token.ts";

const direct = {
  FEEDBACKKIT_APP_KEY: "test-key",
  FEEDBACKKIT_APP: "prhub",
  FEEDBACKKIT_PUBLIC_URL: "https://feedback.example.com/",
  FEEDBACKKIT_URL: "https://feedback.example.com",
  FEEDBACKKIT_TOKEN: "caller",
};

function claims(token: string) {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
}

test("a token is HS256 over the app's key, as FeedbackKit's issueToken signs one", async () => {
  const { token, expiresAt } = await signFeedbackToken(
    "test-key",
    "prhub",
    "octocat",
    1_700_000_000_500,
  );
  const [header, payload, signature] = token.split(".");
  const expected = createHmac("sha256", "test-key")
    .update(`${header}.${payload}`)
    .digest("base64url");
  assert.equal(signature, expected);
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), {
    alg: "HS256",
    typ: "JWT",
  });
  assert.deepEqual(claims(token), {
    iss: "prhub",
    sub: "octocat",
    aud: "feedbackkit",
    iat: 1_700_000_000,
    exp: 1_700_000_900,
  });
  assert.equal(expiresAt, 1_700_000_900_000);
});

test("POST /feedback/token answers the token, when it ends and FeedbackKit's root", async () => {
  const answer = await feedbackTokenRoute(direct, "octocat", 1_700_000_000_000);
  assert.equal(answer.status, 200);
  assert.equal(answer.headers.get("Cache-Control"), "no-store");
  const body = (await answer.json()) as { token: string; expires_at: string; url: string };
  assert.equal(body.url, "https://feedback.example.com");
  assert.equal(body.expires_at, "2023-11-14T22:28:20.000Z");
  assert.equal(claims(body.token).sub, "octocat");
});

test("without the key, the app or an https root the direct path is off: 404, and the config names no root", async () => {
  for (const env of [
    { ...direct, FEEDBACKKIT_APP_KEY: undefined },
    { ...direct, FEEDBACKKIT_APP_KEY: "__FEEDBACKKIT_APP_KEY__" },
    { ...direct, FEEDBACKKIT_APP: undefined },
    { ...direct, FEEDBACKKIT_PUBLIC_URL: "http://feedback.example.com" },
    { ...direct, FEEDBACKKIT_PUBLIC_URL: "__FEEDBACKKIT_PUBLIC_URL__" },
  ]) {
    assert.equal(feedbackDirectURL(env), null);
    assert.equal((await feedbackTokenRoute(env, "octocat")).status, 404);
    assert.equal(deviceConfig(env, "octocat").feedback_direct, undefined);
  }
});

test("the config names FeedbackKit's root when the direct path is on", () => {
  assert.deepEqual(deviceConfig(direct, "octocat").feedback_direct, {
    url: "https://feedback.example.com",
  });
});
