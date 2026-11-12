import assert from "node:assert/strict";
import { test } from "node:test";
import type { FeedbackStore } from "../src/feedback.ts";
import { addIssueFeedback, chatOfRef, type IssueFeedback, issueChat, issueThreads, isImageName } from "../src/feedback-issues.ts";

function memoryStore(): FeedbackStore {
  const objects = new Map<string, string>();
  return {
    async get<T>(key: string) {
      const body = objects.get(key);
      return body ? { value: JSON.parse(body) as T, etag: "v" } : null;
    },
    async put(key, value) {
      objects.set(key, JSON.stringify(value));
      return true;
    },
    async list(prefix) {
      return [...objects.keys()].filter((key) => key.startsWith(prefix));
    },
    async delete(key) {
      objects.delete(key);
    },
  };
}

function world() {
  const opened: Array<{ title: string; body: string }> = [];
  const comments: Array<{ id: number; body: string; login: string; at: string }> = [];
  const images: string[] = [];
  let clock = Date.parse("2026-11-12T10:00:00Z");
  const context: IssueFeedback = {
    store: memoryStore(),
    images: { async put(name) { images.push(name); } },
    issues: {
      async open(title, body) {
        opened.push({ title, body });
        return { number: 7, url: "https://github.com/acme/app/issues/7" };
      },
      async comment(_issue, body) {
        comments.push({ id: comments.length + 1, body, login: "jai", at: new Date(clock).toISOString() });
      },
      async comments() {
        return comments;
      },
    },
    login: "octocat",
    origin: "https://worker.example",
    imagePath: "/feedback/images/",
    repo: "acme/app",
    now: () => (clock += 1000),
  };
  return { context, opened, comments, images };
}

const JPEG = "/9j/4AAQSkZJRg==";

test("new feedback opens a public issue naming its sender, with its screenshots", async () => {
  const { context, opened, images } = world();
  const id = await addIssueFeedback(context, null, {
    text: "The diff font is too small\nOn an iPad", build: "180", images: [{ media_type: "image/jpeg", data: JPEG }],
  });
  assert.ok(id);
  assert.equal(opened[0].title, "The diff font is too small");
  assert.match(opened[0].body, /From @octocat in PRHub \(build 180\)\./);
  assert.equal(images.length, 1);
  assert.ok(isImageName(images[0]));
  assert.match(opened[0].body, new RegExp(`!\\[Screenshot 1\\]\\(https://worker.example/feedback/images/${images[0]}\\)`));
  assert.deepEqual((await issueThreads(context.store)).map((thread) => thread.id), [id]);
});

test("a reply comments on the issue, and others' replies on GitHub show in the chat once", async () => {
  const { context, comments } = world();
  const id = (await addIssueFeedback(context, null, { text: "Add dark diff colours", build: null, images: [] }))!;
  await addIssueFeedback(context, id, { text: "Also for the Mac", build: null, images: [] });
  comments.push({ id: 99, body: "On it.", login: "jai", at: new Date(context.now()).toISOString() });
  const chat = (await issueChat(context, id))!;
  assert.deepEqual(chat.messages.map((message) => [message.role, message.text]), [
    ["you", "Add dark diff colours"],
    ["agent", "Opened [issue #7](https://github.com/acme/app/issues/7). Replies there show here."],
    ["you", "Also for the Mac"],
    ["agent", "**@jai:** On it."],
  ]);
  assert.equal(chat.builderOnline, true);
  assert.equal(chat.isWorking, false);
});

test("a reply to a chat that does not exist is refused, and only random image names are served", async () => {
  const { context } = world();
  assert.equal(await addIssueFeedback(context, "fb_0000000000000000", { text: "hi", build: null, images: [] }), null);
  assert.equal(isImageName("../users/1/secret.json"), false);
  assert.equal(isImageName(`${"a".repeat(32)}.png`), true);
});

test("sends at once all keep, and a retried new chat finds the chat it made", async () => {
  const { context } = world();
  const [a, b] = await Promise.all(["first", "second"].map((text) =>
    addIssueFeedback(context, null, { text, build: null, images: [] }, text)));
  assert.deepEqual(new Set((await issueThreads(context.store)).map((thread) => thread.id)), new Set([a, b]));
  await Promise.all(["one", "two"].map((text) => addIssueFeedback(context, a, { text, build: null, images: [] })));
  const mine = (await issueChat(context, a!))!.messages.filter((message) => message.role === "you").map((m) => m.text);
  assert.deepEqual(mine.sort(), ["first", "one", "two"]);
  assert.equal(await chatOfRef(context.store, "second"), b);
  assert.equal(await chatOfRef(context.store, "third"), null);
});
