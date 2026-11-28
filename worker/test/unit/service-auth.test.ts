import { describe, expect, it } from "vitest";
import { NO_AI } from "../../src/account-core.ts";
import type { AccountApi } from "../../src/account-of.ts";
import type { Env } from "../../src/env.ts";
import { authenticateService, publicHostedRoute } from "../../src/hosted.ts";
import { APP, hostedWorld, ORIGIN } from "../support/hosted-world.ts";

function fakeEnv(serviceToken?: string): Env {
  return {
    GITHUB_TOKEN: "",
    SERVICE_TOKEN: serviceToken,
    SUBSCRIPTION_LOGINS: "jai",
    CLAUDE_CODE_OAUTH_TOKEN: "sub-tok",
  } as unknown as Env;
}

function fakeServices(result: Awaited<ReturnType<AccountApi["accessToken"]>>) {
  return {
    account: () =>
      ({
        accessToken: async () => result,
      }) as unknown as AccountApi,
  };
}

describe("authenticateService", () => {
  it("returns null when X-PRHub-Service-Token is absent", async () => {
    const req = new Request("https://prhub.test/prs");
    const res = await authenticateService(
      req,
      fakeEnv("secret-tok"),
      fakeServices({ kind: "signed_out" }),
    );
    expect(res).toBeNull();
  });

  it("rejects with 401 when SERVICE_TOKEN is unset or mismatched", async () => {
    const req = new Request("https://prhub.test/prs", {
      headers: { "X-PRHub-Service-Token": "wrong", "X-PRHub-User-Id": "1943284" },
    });
    const r1 = await authenticateService(
      req,
      fakeEnv(undefined),
      fakeServices({ kind: "signed_out" }),
    );
    expect(r1 && "answer" in r1 && r1.answer.status).toBe(401);
    const r2 = await authenticateService(
      req,
      fakeEnv("right"),
      fakeServices({ kind: "signed_out" }),
    );
    expect(r2 && "answer" in r2 && r2.answer.status).toBe(401);
  });

  it("rejects invalid or missing X-PRHub-User-Id with 400", async () => {
    const req = new Request("https://prhub.test/prs", {
      headers: { "X-PRHub-Service-Token": "right", "X-PRHub-User-Id": "not-a-num" },
    });
    const r = await authenticateService(
      req,
      fakeEnv("right"),
      fakeServices({ kind: "signed_out" }),
    );
    expect(r && "answer" in r && r.answer.status).toBe(400);
  });

  it("resolves delegated userEnv for a valid service token and signed-in user", async () => {
    const req = new Request("https://prhub.test/prs", {
      headers: { "X-PRHub-Service-Token": "right", "X-PRHub-User-Id": "1943284" },
    });
    const r = await authenticateService(
      req,
      fakeEnv("right"),
      fakeServices({ kind: "ok", userId: "1943284", login: "jai", token: "ghu_live", ai: NO_AI }),
    );
    expect(r && "env" in r).toBe(true);
    if (r && "env" in r) {
      expect(r.userId).toBe("1943284");
      expect(r.env.SIGNED_IN_USER_ID).toBe("1943284");
      expect(r.env.GITHUB_LOGIN).toBe("jai");
      expect(r.env.GITHUB_TOKEN).toBe("ghu_live");
      expect(r.env.CLAUDE_CODE_OAUTH_TOKEN).toBe("sub-tok");
    }
  });
});

describe("publicHostedRoute /prs/states gating", () => {
  it("returns 404 for /prs/states without X-PRHub-Service-Token or on non-POST methods", async () => {
    const world = hostedWorld();
    const unauth = await publicHostedRoute(
      new Request(`${ORIGIN}/prs/states`, { method: "POST" }),
      world.workerEnv,
      world.services,
      APP,
      () => {},
    );
    expect(unauth?.status).toBe(404);

    const wrongMethod = await publicHostedRoute(
      new Request(`${ORIGIN}/prs/states`, {
        method: "GET",
        headers: { "X-PRHub-Service-Token": "right", "X-PRHub-User-Id": "1943284" },
      }),
      world.workerEnv,
      world.services,
      APP,
      () => {},
    );
    expect(wrongMethod?.status).toBe(404);

    const selfHostedOnly = await publicHostedRoute(
      new Request(`${ORIGIN}/device/pair`, {
        method: "POST",
        headers: { "X-PRHub-Service-Token": "right", "X-PRHub-User-Id": "1943284" },
      }),
      world.workerEnv,
      world.services,
      APP,
      () => {},
    );
    expect(selfHostedOnly?.status).toBe(404);
  });

  it("lets service-authenticated POST /prs/states pass through to serveHosted", () => {
    const world = hostedWorld();
    const res = publicHostedRoute(
      new Request(`${ORIGIN}/prs/states`, {
        method: "POST",
        headers: { "X-PRHub-Service-Token": "right", "X-PRHub-User-Id": "1943284" },
      }),
      world.workerEnv,
      world.services,
      APP,
      () => {},
    );
    expect(res).toBeNull();
  });
});
