// Ask's GitHub tokens (`app-token.ts`): read only and narrowed to the repos the person's own token can see, minted by a
// fake GitHub App with a real RSA key made in the test.
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { test, vi } from "vitest";
import {
  askGrant,
  askRepoToken,
  installationRepoToken,
  VISIBLE_REPOS_MS,
} from "../../src/app-token.ts";
import type { Env } from "../../src/env.ts";
import { userEnv } from "../../src/hosted.ts";
import { parseRepoFullName, type RepoFullName } from "../../src/ids.ts";

const repo = (name: string) => parseRepoFullName(name) as RepoFullName;

const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const PEM = privateKey.export({ type: "pkcs8", format: "pem" }).toString();

function appGitHub() {
  const calls: { url: string; body: unknown; auth: string }[] = [];
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({
      url,
      body: init?.body ? JSON.parse(String(init.body)) : null,
      auth: new Headers(init?.headers).get("Authorization") ?? "",
    });
    if (url.endsWith("/installation")) {
      return Response.json({ id: 77 });
    }
    return Response.json({ token: "installation-token" }, { status: 201 });
  }) as typeof fetch;
  return { calls, fetcher };
}

test("the hosted Ask token is minted read only, for the one repo", async () => {
  const { calls, fetcher } = appGitHub();
  const token = await installationRepoToken(
    repo("acme/api"),
    { id: "123", key: PEM },
    true,
    fetcher,
  );
  assert.equal(token, "installation-token");
  assert.match(calls[0].auth, /^Bearer [\w-]+\.[\w-]+\.[\w-]+$/, "the App's JWT");
  const minted = calls[1].body as { repositories: string[]; permissions: Record<string, string> };
  assert.equal(calls[1].url, "https://api.github.com/app/installations/77/access_tokens");
  assert.deepEqual(minted.repositories, ["api"]);
  assert.ok(Object.values(minted.permissions).every((level) => level === "read"));
});

test("no Ask token is minted for a PR the person's own token cannot read", async () => {
  const real = globalThis.fetch;
  const { calls, fetcher } = appGitHub();
  const asked: string[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    asked.push(`${String(input)} ${new Headers(init?.headers).get("Authorization")}`);
    return String(input).endsWith("/repos/acme/secret/pulls/7")
      ? new Response("{}", { status: 404 })
      : Response.json({ number: 7 });
  }) as typeof fetch;
  try {
    const person = userEnv({ GITHUB_APP_ID: "123", GITHUB_APP_PRIVATE_KEY: PEM } as Env, {
      userId: "1001",
      login: "alice",
      token: "ghu_alice",
    });
    await assert.rejects(
      askRepoToken(repo("acme/secret"), 7, person, fetcher),
      /can't see this pull request/,
    );
    assert.equal(calls.length, 0, "the App was never asked");
    assert.equal(await askRepoToken(repo("acme/api"), 7, person, fetcher), "installation-token");
    assert.deepEqual(asked, [
      "https://api.github.com/repos/acme/secret/pulls/7 Bearer ghu_alice",
      "https://api.github.com/repos/acme/api/pulls/7 Bearer ghu_alice",
    ]);
  } finally {
    globalThis.fetch = real;
  }
});

/** The person's own GitHub, as their token reads it: `prs` they can see, `visible` repos of installation 77. */
async function withPersonGitHub<T>(
  { prs, visible }: { prs: string[]; visible: string[] },
  run: (asked: string[]) => Promise<T>,
): Promise<T> {
  const real = globalThis.fetch;
  const asked: string[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    asked.push(`${url} ${new Headers(init?.headers).get("Authorization")}`);
    if (url.includes("/user/installations/77/repositories")) {
      return Response.json({ repositories: visible.map((full_name) => ({ full_name })) });
    }
    return prs.some((pr) => url.endsWith(`/repos/${pr}`))
      ? Response.json({ number: 7 })
      : new Response("{}", { status: 404 });
  }) as typeof fetch;
  try {
    return await run(asked);
  } finally {
    globalThis.fetch = real;
  }
}

function memoryDiffs() {
  const objects = new Map<string, string>();
  return {
    get: async (key: string) =>
      objects.has(key) ? { json: async () => JSON.parse(objects.get(key)!) } : null,
    put: async (key: string, value: string) => void objects.set(key, value),
  };
}

function hostedPerson() {
  return userEnv(
    { GITHUB_APP_ID: "123", GITHUB_APP_PRIVATE_KEY: PEM, DIFFS: memoryDiffs() } as unknown as Env,
    { userId: "1001", login: "alice", token: "ghu_alice" },
  );
}

test("hosted, a subscription question's token names every repo of the installation the person can see, and no other", async () => {
  const { calls, fetcher } = appGitHub();
  const person = hostedPerson();
  await withPersonGitHub(
    { prs: ["acme/api/pulls/7"], visible: ["acme/api", "acme/actions"] },
    async (asked) => {
      const grant = await askGrant(repo("acme/api"), 7, person, fetcher, 1_000);
      assert.equal(grant.token, "installation-token");
      assert.deepEqual(grant.repos, ["acme/api", "acme/actions"]);
      const minted = calls[1].body as {
        repositories: string[];
        permissions: Record<string, string>;
      };
      assert.deepEqual(
        minted.repositories,
        ["api", "actions"],
        "the sibling repo the person can see",
      );
      assert.ok(Object.values(minted.permissions).every((level) => level === "read"));
      assert.ok(
        asked.every((call) => call.endsWith("Bearer ghu_alice")),
        "visibility is read with the person's token",
      );
      assert.ok(
        calls.every(({ auth }) => !auth.includes("ghu_alice")),
        "which never goes to the App's calls",
      );
      const listed = asked.filter((call) => call.includes("/user/installations/77/")).length;
      await askGrant(repo("acme/api"), 7, person, fetcher, 1_000 + VISIBLE_REPOS_MS - 1);
      assert.equal(
        asked.filter((call) => call.includes("/user/installations/77/")).length,
        listed,
        "kept a while",
      );
      await askGrant(repo("acme/api"), 7, person, fetcher, 1_000 + VISIBLE_REPOS_MS);
      assert.equal(
        asked.filter((call) => call.includes("/user/installations/77/")).length,
        listed + 1,
        "then read again",
      );
    },
  );
});

test("hosted, a repo the person can't see stays out of the token", async () => {
  const { calls, fetcher } = appGitHub();
  await withPersonGitHub({ prs: ["acme/api/pulls/7"], visible: ["acme/api"] }, async () => {
    const grant = await askGrant(repo("acme/api"), 7, hostedPerson(), fetcher, 1_000);
    assert.deepEqual(grant.repos, ["acme/api"]);
    assert.deepEqual((calls[1].body as { repositories: string[] }).repositories, ["api"]);
  });
});

test("hosted, no token for a PR the person can't see, and a clear refusal where the App isn't installed", async () => {
  const { calls, fetcher } = appGitHub();
  await withPersonGitHub({ prs: [], visible: [] }, async () => {
    await assert.rejects(
      askGrant(repo("acme/secret"), 7, hostedPerson(), fetcher),
      /can't see this pull request/,
    );
    assert.equal(calls.length, 0, "the App was never asked");
  });
  const notInstalled = (async () => new Response("{}", { status: 404 })) as unknown as typeof fetch;
  await withPersonGitHub({ prs: ["other/api/pulls/7"], visible: [] }, async () => {
    await assert.rejects(
      askGrant(repo("other/api"), 7, hostedPerson(), notInstalled),
      /GitHub App isn't installed there/,
    );
  });
});

test("hosted, with the person's GitHub limit used up, only the repos their own token listed lately stand in for it", async () => {
  // GitHub's limit resets an hour after the test's clock, so the Worker holds it for the whole test.
  const now = Date.parse("2026-11-01T00:00:00Z");
  vi.useFakeTimers({ toFake: ["Date"], now });
  const reset = String(now / 1_000 + 3_600);
  const real = globalThis.fetch;
  globalThis.fetch = (async () =>
    new Response("{}", {
      status: 403,
      headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": reset },
    })) as unknown as typeof fetch;
  try {
    const { fetcher } = appGitHub();
    const person = hostedPerson();
    await assert.rejects(
      askGrant(repo("acme/api"), 7, person, fetcher, 1_000),
      /rate limit for your account is used up/,
      "with no list kept, the limit is the answer",
    );
    await person.DIFFS.put(
      "users/1001/ask-reach/77.json",
      JSON.stringify({ at: 1_000, repos: ["acme/api"] }),
    );
    const grant = await askGrant(repo("acme/api"), 7, person, fetcher, 2_000);
    assert.equal(grant.checkedBy, "person_cached");
    assert.deepEqual(grant.repos, ["acme/api"]);
    await assert.rejects(
      askGrant(repo("acme/secret"), 7, person, fetcher, 2_000),
      /rate limit/,
      "a repo not on their list gets no token",
    );
    await assert.rejects(
      askGrant(repo("acme/api"), 7, person, fetcher, 1_000 + VISIBLE_REPOS_MS),
      /rate limit/,
      "an old list stands in for nothing",
    );
  } finally {
    globalThis.fetch = real;
  }
});

test("Jai's Worker: where his Ask App isn't installed, the Worker's token checks the PR out, not read only", async () => {
  const notInstalled = (async () => new Response("{}", { status: 404 })) as unknown as typeof fetch;
  const env = {
    ASK_GITHUB_APP_ID: "9",
    ASK_GITHUB_APP_KEY: PEM,
    GITHUB_TOKEN: "worker-token",
  } as unknown as Env;
  const grant = await askGrant(repo("jai/prhub"), 48, env, notInstalled);
  assert.deepEqual(grant, { token: "worker-token", repos: null, readOnly: false });
  const refused = (async () => new Response("{}", { status: 403 })) as unknown as typeof fetch;
  await assert.rejects(
    askGrant(repo("jai/prhub"), 48, env, refused),
    /GitHub App isn't installed|read access/,
    "any other refusal still fails the turn",
  );
});
