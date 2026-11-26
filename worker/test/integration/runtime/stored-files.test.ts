// A file at a PR's head through the Worker's own route: the real bucket binding and the real index.
import { env, exports } from "cloudflare:workers";
import { expect, test, vi } from "vitest";
import { authorization } from "./values.ts";

const HEAD = "a".repeat(40);
const PATH = "src/checkout/payments.ts";
const URL = `https://prhub.test/prs/acme/app/7/file?path=${encodeURIComponent(PATH)}&head=${HEAD}`;

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

test("a file kept in the real R2 bucket is served byte for byte without asking GitHub", async () => {
  // Latin-1, not UTF-8: the bytes must come back as they went in.
  const bytes = new Uint8Array([0x63, 0x61, 0x66, 0xe9, 0x0a]);
  await env.DIFFS.put(`acme/app/7/${HEAD}/file/${await sha256Hex(PATH)}`, bytes);
  const response = await exports.default.fetch(URL, { headers: authorization });
  expect(response.status).toBe(200);
  expect(response.headers.get("Content-Type")).toBe("text/plain; charset=utf-8");
  expect(new Uint8Array(await response.arrayBuffer())).toEqual(bytes);
  expect(response.headers.get("Server-Timing")).toBe('github;desc="github calls";dur=0');
});

test("a file of a PR on no list is read from GitHub once its head is checked, then from the bucket", async () => {
  const asked: string[] = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
    const url = String(input instanceof Request ? input.url : input);
    asked.push(url);
    return url.endsWith("/pulls/7")
      ? Response.json({ head: { sha: HEAD }, base: { ref: "main" } })
      : new Response("export const retries = 2;\n", {
          headers: { "Content-Type": "application/vnd.github.raw+json; charset=utf-8" },
        });
  });
  const first = await exports.default.fetch(URL, { headers: authorization });
  expect(await first.text()).toBe("export const retries = 2;\n");
  expect(first.headers.get("Server-Timing")).toBe('github;desc="github calls";dur=2');
  expect(asked).toEqual([
    "https://api.github.com/repos/acme/app/pulls/7",
    `https://api.github.com/repos/acme/app/contents/${PATH}?ref=${HEAD}`,
  ]);
  await vi.waitFor(async () => expect((await env.DIFFS.list()).objects).toHaveLength(1));
  const second = await exports.default.fetch(URL, { headers: authorization });
  expect(await second.text()).toBe("export const retries = 2;\n");
  expect(second.headers.get("Server-Timing")).toBe('github;desc="github calls";dur=0');
});

test("the file route is behind the bearer, takes only a GET, and refuses a bad path or head", async () => {
  expect((await exports.default.fetch(URL)).status).toBe(401);
  const post = await exports.default.fetch(URL, { method: "POST", headers: authorization });
  expect(post.status).toBe(404);
  for (const query of [`path=../x&head=${HEAD}`, `path=${PATH}&head=main`]) {
    const response = await exports.default.fetch(
      `https://prhub.test/prs/acme/app/7/file?${query}`,
      { headers: authorization },
    );
    expect(response.status).toBe(400);
  }
});
