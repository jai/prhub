// `GET …/file`: one file at the PR's head, from GitHub once and then from the asker's own copies.
import assert from "node:assert/strict";
import { test } from "vitest";
import { prId, repoOf } from "../../src/ids.ts";
import { fileRoute, MAX_FILE_BYTES, parseFilePath } from "../../src/pr-file.ts";
import { sweepClosedPullRequests } from "../../src/retention.ts";
import { env as envOf } from "../support/env.ts";
import { type Answer, stubFetch } from "../support/fake-fetch.ts";
import { memoryR2, type MemoryR2 } from "../support/memory-r2.ts";

const HEAD = "a".repeat(40);
const PATH = "src/checkout/payments.ts";
const FILE_URL = `https://api.github.com/repos/acme/app/contents/${PATH}?ref=${HEAD}`;
const PULL_URL = "https://api.github.com/repos/acme/app/pulls/7";
const TEXT = "export const retries = 2;\n";
const RAW = { "Content-Type": "application/vnd.github.raw+json; charset=utf-8" };

const owner = envOf({ GITHUB_TOKEN: "ghp_owner" });
const alice = envOf({ GITHUB_TOKEN: "ghu_alice", SIGNED_IN_USER_ID: "1001" });
const bob = envOf({ GITHUB_TOKEN: "ghu_bob", SIGNED_IN_USER_ID: "2002" });

/** One request to the route, its stored copy written before it answers. */
async function ask(
  bucket: MemoryR2,
  { env = owner, path = PATH, head = HEAD, indexed = HEAD as string | null } = {},
  params = new URLSearchParams({ path, head }),
): Promise<Response> {
  const writes: Promise<unknown>[] = [];
  const response = await fileRoute("acme/app", 7, params, env, {
    store: bucket.binding,
    indexedHead: async () => indexed,
    waitUntil: (promise) => writes.push(promise),
  });
  await Promise.all(writes);
  return response;
}

const codeOf = async (response: Response) =>
  ((await response.json()) as { error: { code: string } }).error.code;

test("a file at the PR's head is GitHub's raw bytes, and a second read comes from the stored copy", async () => {
  const asked = stubFetch(() => new Response(TEXT, { headers: RAW }));
  const bucket = memoryR2();
  const first = await ask(bucket);
  assert.equal(first.status, 200);
  assert.equal(first.headers.get("Content-Type"), "text/plain; charset=utf-8");
  assert.equal(await first.text(), TEXT);
  assert.deepEqual(
    asked.map((one) => [one.url, one.token, one.headers.get("Accept")]),
    [[FILE_URL, "ghp_owner", "application/vnd.github.raw+json"]],
  );
  const [key] = [...bucket.objects.keys()];
  assert.match(key, new RegExp(`^acme/app/7/${HEAD}/file/[0-9a-f]{64}$`));

  const second = await ask(bucket);
  assert.equal(await second.text(), TEXT);
  assert.equal(second.headers.get("Content-Type"), "text/plain; charset=utf-8");
  assert.equal(asked.length, 1, "the copy answered");
});

test("each segment of the path is encoded on its way to GitHub", async () => {
  const asked = stubFetch(() => new Response(TEXT, { headers: RAW }));
  await ask(memoryR2(), { path: "docs/what's new?/a b#1.md" });
  assert.equal(
    asked[0].url,
    `https://api.github.com/repos/acme/app/contents/docs/what's%20new%3F/a%20b%231.md?ref=${HEAD}`,
  );
});

test("one person's stored file is not another's: each reads GitHub with their own token", async () => {
  const asked = stubFetch(() => new Response(TEXT, { headers: RAW }));
  const bucket = memoryR2();
  await ask(bucket, { env: alice });
  const [key] = [...bucket.objects.keys()];
  assert.ok(key.startsWith(`users/1001/acme/app/7/${HEAD}/file/`));

  // GitHub refuses bob the repo: alice's copy must not answer him.
  const refused: Answer = () => Response.json({ message: "Not Found" }, { status: 404 });
  const bobAsked = stubFetch(refused);
  const response = await ask(bucket, { env: bob, indexed: null });
  assert.equal(response.status, 404);
  assert.deepEqual(
    bobAsked.map((one) => [one.url, one.token]),
    [[PULL_URL, "ghu_bob"]],
  );
  assert.equal(asked.length, 1);
  assert.deepEqual([...bucket.objects.keys()], [key], "nothing is kept for him");
});

test("a path that could name anything but a file in the repo is refused before GitHub is asked", async () => {
  const asked = stubFetch(() => new Response(TEXT, { headers: RAW }));
  for (const path of [
    "",
    "/etc/passwd",
    "src/../../secrets.ts",
    "..",
    "src//payments.ts",
    "src/./payments.ts",
    "src/payments.ts/",
    "src/pay\nments.ts",
    "src/pay\u0000ments.ts",
    "src/pay\u007fments.ts",
    "a".repeat(1_025),
  ]) {
    const response = await ask(memoryR2(), { path });
    assert.equal(response.status, 400, JSON.stringify(path.slice(0, 40)));
    assert.equal(await codeOf(response), "validation_error");
  }
  assert.equal((await ask(memoryR2(), {}, new URLSearchParams({ head: HEAD }))).status, 400);
  assert.equal(asked.length, 0);
  assert.equal(parseFilePath("a".repeat(1_024)), "a".repeat(1_024));
  assert.equal(parseFilePath("src/..hidden/a...b.ts"), "src/..hidden/a...b.ts");
});

test("a head that is not a full commit is refused before GitHub is asked", async () => {
  const asked = stubFetch(() => new Response(TEXT, { headers: RAW }));
  for (const head of ["", "main", "a".repeat(39), "A".repeat(40), `${"a".repeat(40)}/../x`]) {
    const response = await ask(memoryR2(), { head });
    assert.equal(response.status, 400, head);
    assert.equal(await codeOf(response), "validation_error");
  }
  assert.equal((await ask(memoryR2(), {}, new URLSearchParams({ path: PATH }))).status, 400);
  assert.equal(asked.length, 0);
});

test("a PR on none of the person's lists is checked with GitHub: its head now is served", async () => {
  const asked = stubFetch((one) =>
    one.url === PULL_URL
      ? Response.json({ head: { sha: HEAD }, base: { ref: "main" } })
      : new Response(TEXT, { headers: RAW }),
  );
  const bucket = memoryR2();
  const response = await ask(bucket, { indexed: null });
  assert.equal(await response.text(), TEXT);
  assert.deepEqual(
    asked.map((one) => one.url),
    [PULL_URL, FILE_URL],
  );
  await ask(bucket, { indexed: null });
  assert.equal(asked.length, 2, "the copy answers without the check");
});

test("a commit that is not the PR's head is refused, and its file is never read", async () => {
  for (const indexed of [null, "c".repeat(40)]) {
    const asked = stubFetch(() => Response.json({ head: { sha: "b".repeat(40) } }));
    const bucket = memoryR2();
    const response = await ask(bucket, { indexed });
    assert.equal(response.status, 409);
    assert.equal(await codeOf(response), "head_moved");
    assert.deepEqual(
      asked.map((one) => one.url),
      [PULL_URL],
    );
    assert.equal(bucket.objects.size, 0);
  }
});

test("a head newer than the index's is served once GitHub says it is the PR's head", async () => {
  stubFetch((one) =>
    one.url === PULL_URL
      ? Response.json({ head: { sha: HEAD } })
      : new Response(TEXT, { headers: RAW }),
  );
  const response = await ask(memoryR2(), { indexed: "c".repeat(40) });
  assert.equal(await response.text(), TEXT);
});

test("a file over 1 MB is refused by its Content-Length, and by its bytes when GitHub sends none", async () => {
  const big = "x".repeat(MAX_FILE_BYTES + 1);
  for (const headers of [{ ...RAW, "Content-Length": String(big.length) }, RAW]) {
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(big.slice(0, 700_000)));
        controller.enqueue(new TextEncoder().encode(big.slice(700_000)));
        controller.close();
      },
    });
    stubFetch(() => new Response(body, { headers }));
    const bucket = memoryR2();
    const response = await ask(bucket);
    assert.equal(response.status, 413);
    assert.equal(await codeOf(response), "too_large");
    assert.equal(bucket.objects.size, 0);
  }
});

test("a file of exactly 1 MB is served", async () => {
  stubFetch(() => new Response("x".repeat(MAX_FILE_BYTES), { headers: RAW }));
  const response = await ask(memoryR2());
  assert.equal(response.status, 200);
  assert.equal((await response.arrayBuffer()).byteLength, MAX_FILE_BYTES);
});

test("a path GitHub has no file at is 404, and nothing is kept", async () => {
  stubFetch(() => Response.json({ message: "Not Found" }, { status: 404 }));
  const bucket = memoryR2();
  const response = await ask(bucket);
  assert.equal(response.status, 404);
  assert.equal(await codeOf(response), "not_found");
  assert.equal(bucket.objects.size, 0);
});

test("a directory or submodule, which GitHub answers as JSON, is 404", async () => {
  const answers = [
    [{ type: "file", name: "payments.ts", path: PATH }],
    { type: "submodule", path: PATH, submodule_git_url: "https://github.com/acme/lib.git" },
  ];
  for (const answer of answers) {
    stubFetch(() =>
      Response.json(answer, { headers: { "Content-Type": "application/json; charset=utf-8" } }),
    );
    const bucket = memoryR2();
    const response = await ask(bucket);
    assert.equal(response.status, 404);
    assert.equal(await codeOf(response), "not_found");
    assert.equal(bucket.objects.size, 0);
  }
});

test("a file with a NUL in its first 8 KB is binary: 415, and nothing is kept", async () => {
  stubFetch(
    () => new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 1, 2]), { headers: RAW }),
  );
  const bucket = memoryR2();
  const response = await ask(bucket);
  assert.equal(response.status, 415);
  assert.equal(await codeOf(response), "binary_file");
  assert.equal(bucket.objects.size, 0);
});

test("any other answer of GitHub's is passed on as the diff's is", async () => {
  stubFetch(() => Response.json({ message: "Server Error" }, { status: 502 }));
  const bucket = memoryR2();
  const response = await ask(bucket);
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { message: "Server Error" });
  assert.equal(bucket.objects.size, 0);
});

test("the retention sweep takes a closed PR's stored files with its diffs", async () => {
  stubFetch(() => new Response(TEXT, { headers: RAW }));
  const bucket = memoryR2();
  await ask(bucket, { env: alice });
  bucket.objects.set("users/1001/acme/app/8/r1.diff", {
    body: "",
    customMetadata: {},
    uploaded: new Date(0),
  });
  const deleted = await sweepClosedPullRequests(
    bucket.binding,
    "users/1001/",
    (id) => id === prId(repoOf("acme/app"), 8),
    1,
  );
  assert.equal(deleted, 1);
  assert.deepEqual([...bucket.objects.keys()], ["users/1001/acme/app/8/r1.diff"]);
});
