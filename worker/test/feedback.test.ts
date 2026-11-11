import assert from "node:assert/strict";
import { test } from "node:test";
import {
  addFeedback, builderStatusOf, feedbackChat, feedbackList, type FeedbackStore, isFeedbackId, listServedLog,
  parseAgentSide, parseFeedbackInput,
  runnerAgent, runnerClaim, runnerPoll, runnerResult, titleOf,
} from "../src/feedback.ts";

/** R2 as feedback.ts uses it: a version per write, and a put over a version that has moved refused. */
function memoryStore(): FeedbackStore & { objects: Map<string, { body: string; etag: string }> } {
  const objects = new Map<string, { body: string; etag: string }>();
  let version = 0;
  return {
    objects,
    async get<T>(key: string) {
      const object = objects.get(key);
      return object ? { value: JSON.parse(object.body) as T, etag: object.etag } : null;
    },
    async put(key, value, ifEtag) {
      if (ifEtag !== undefined && objects.get(key)?.etag !== ifEtag) {
        return false;
      }
      objects.set(key, { body: JSON.stringify(value), etag: `v${++version}` });
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

const PNG = "iVBORw0KGgoAAAANSUhEUg==";
const JPEG = "/9j/4AAQSkZJRg==";

test("feedback is words with the build it is about, and nothing else gets through", () => {
  assert.deepEqual(parseFeedbackInput({ text: "  The back button jumps  ", build: "142" }),
    { text: "The back button jumps", build: "142", images: [] });
  assert.equal(parseFeedbackInput({ text: "   " }), null);
  assert.equal(parseFeedbackInput({ text: "x".repeat(8_001) }), null);
  assert.equal(parseFeedbackInput({ text: "ok", build: "1; rm -rf /" })?.build, null);
  assert.equal(isFeedbackId("fb_0123456789abcdef"), true);
  assert.equal(isFeedbackId("sesn_011CgjX"), false);
  assert.equal(isFeedbackId("../chats.json"), false);
  assert.equal(titleOf(`${"a".repeat(80)}\nsecond line`).length, 60);
  assert.equal(titleOf(""), "Screenshot");
});

test("only up to four JPEG or PNG screenshots of at most 1.5 MB get through", () => {
  const one = { media_type: "image/jpeg", data: JPEG };
  assert.equal(parseFeedbackInput({ text: "x", images: [one, one, one, one] })?.images.length, 4);
  for (const images of [
    [one, one, one, one, one],
    [{ media_type: "image/gif", data: JPEG }],
    [{ media_type: "image/png", data: JPEG }],
    [{ media_type: "image/jpeg", data: "/9j/ not base64" }],
    [{ media_type: "image/jpeg", data: `/9j/${"A".repeat(2_000_000)}` }],
    "nope",
  ]) {
    assert.equal(parseFeedbackInput({ text: "x", images }), null);
  }
});

test("new feedback waits for the runner: the chat works and the builder is offline until a poll", async () => {
  const store = memoryStore();
  const input = parseFeedbackInput({ text: "Bigger clock", build: "180", images: [{ media_type: "image/png", data: PNG }] })!;
  const chat = (await addFeedback(store, null, input, 1_000))!;
  assert.equal((await feedbackList(store, 2_000)).threads[0].title, "Bigger clock");
  const waiting = (await feedbackChat(store, chat, 2_000))!;
  assert.deepEqual(waiting.messages.map(({ role, text, images }) => ({ role, text, images })),
    [{ role: "you", text: "Bigger clock", images: 1 }]);
  assert.equal(waiting.isWorking, true);
  assert.equal(waiting.builderOnline, false);
  assert.equal(waiting.costCents, null);
  const work = await runnerPoll(store, true, 3_000);
  assert.deepEqual(work.map(({ chat: id, first }) => ({ id, first })), [{ id: chat, first: true }]);
  assert.equal((await feedbackChat(store, chat, 4_000))!.activity, "Starting");
  assert.equal((await feedbackList(store, 3_000 + 91_000)).builderOnline, false, "a runner quiet for 90 s is offline");
  assert.equal(await addFeedback(store, "fb_0000000000000000", input, 5_000), null, "a reply to no chat");
});

test("a later message in a chat goes to its agent, not a new one, and says so while it waits", async () => {
  const store = memoryStore();
  const chat = (await addFeedback(store, null, parseFeedbackInput({ text: "Bigger clock" })!, 1_000))!;
  const [first] = await runnerPoll(store, true, 2_000);
  await runnerClaim(store, chat, first.message, 2_001);
  assert.equal(await runnerResult(store, chat, first.message, true, null), 200);
  assert.equal(await addFeedback(store, chat, parseFeedbackInput({ text: "And bolder" })!, 3_000), chat);
  const work = await runnerPoll(store, true, 3_500);
  assert.deepEqual(work.map(({ chat: id, first: isFirst }) => ({ id, isFirst })), [{ id: chat, isFirst: false }]);
  assert.equal((await feedbackChat(store, chat, 4_000))!.activity, "Passing your message to the agent");
  assert.equal((await feedbackList(store, 4_000)).threads.length, 1, "still one chat");
});

test("a message is claimed once, with its screenshots, then reported on", async () => {
  const store = memoryStore();
  const chat = (await addFeedback(store, null,
    parseFeedbackInput({ text: "Bigger clock", images: [{ media_type: "image/png", data: PNG }] })!, 1_000))!;
  const [work] = await runnerPoll(store, true, 2_000);
  const claimed = await runnerClaim(store, chat, work.message, 3_000);
  assert.ok(claimed.ok);
  assert.deepEqual(claimed.images, [{ media_type: "image/png", data: PNG }]);
  assert.equal(claimed.title, "Bigger clock");
  assert.deepEqual(await runnerClaim(store, chat, work.message, 3_001), { ok: false, status: 409 });
  assert.deepEqual(await runnerPoll(store, true, 3_002), [], "a claimed message leaves the queue");
  assert.equal(await runnerResult(store, chat, work.message, false, "the clone failed"), 200);
  assert.equal(await runnerResult(store, chat, work.message, true, null), 409);
  const failed = (await feedbackChat(store, chat, 4_000))!;
  assert.equal(failed.problem, "the clone failed");
  assert.equal(failed.isWorking, false);
});

test("a claim that loses the race to another is refused", async () => {
  const store = memoryStore();
  const chat = (await addFeedback(store, null, parseFeedbackInput({ text: "x" })!, 1_000))!;
  const [work] = await runnerPoll(store, true, 2_000);
  const put = store.put.bind(store);
  store.put = async (key, value, ifEtag) => {
    if (ifEtag) {
      await put(key, { moved: true });
    }
    return put(key, value, ifEtag);
  };
  assert.deepEqual(await runnerClaim(store, chat, work.message, 3_000), { ok: false, status: 409 });
});

test("the chat is Jai's messages and the agent's in time order, working until the agent's turn ends", async () => {
  const store = memoryStore();
  const chat = (await addFeedback(store, null, parseFeedbackInput({ text: "Bigger clock" })!, Date.parse("2026-11-09T10:00:00Z")))!;
  const [work] = await runnerPoll(store, true, Date.parse("2026-11-09T10:00:05Z"));
  await runnerClaim(store, chat, work.message, Date.parse("2026-11-09T10:00:06Z"));
  await runnerResult(store, chat, work.message, true, null);
  const delivered = (await feedbackChat(store, chat, Date.parse("2026-11-09T10:00:07Z")))!;
  assert.equal(delivered.isWorking, true, "delivered, and the runner has not looked since");
  const side = parseAgentSide({
    messages: [{ id: "a1", text: "On it.", at: "2026-11-09T10:00:20Z" }], isWorking: true, activity: "Running tests",
    thread: { host: "build-mac", id: "orca-claude:abc" },
  }, Date.parse("2026-11-09T10:00:30Z"))!;
  assert.equal(await runnerAgent(store, chat, side), 200);
  const working = (await feedbackChat(store, chat, Date.parse("2026-11-09T10:00:31Z")))!;
  assert.deepEqual(working.messages.map(({ role, text }) => `${role}: ${text}`), ["you: Bigger clock", "agent: On it."]);
  assert.equal(working.activity, "Running tests");
  assert.deepEqual(working.thread, { host: "build-mac", id: "orca-claude:abc" });
  await runnerAgent(store, chat, { ...side, isWorking: false, activity: null, updatedAt: Date.parse("2026-11-09T10:01:00Z") });
  const done = (await feedbackChat(store, chat, Date.parse("2026-11-09T10:01:01Z")))!;
  assert.equal(done.isWorking, false);
  assert.equal(done.activity, null);
  const reply = await addFeedback(store, chat, parseFeedbackInput({ text: "And the badge" })!, Date.parse("2026-11-09T10:02:00Z"));
  assert.equal(reply, chat);
  const [next] = await runnerPoll(store, true, Date.parse("2026-11-09T10:02:01Z"));
  assert.equal(next.first, false);
  assert.equal((await feedbackChat(store, chat, Date.parse("2026-11-09T10:02:02Z")))!.messages.at(-1)!.text, "And the badge");
});

test("a message the runner took and never reported on fails after 15 minutes, and is not sent again", async () => {
  const store = memoryStore();
  const chat = (await addFeedback(store, null, parseFeedbackInput({ text: "x" })!, 1_000))!;
  const [work] = await runnerPoll(store, true, 2_000);
  await runnerClaim(store, chat, work.message, 3_000);
  const stuck = (await feedbackChat(store, chat, 3_000 + 15 * 60_000 + 1))!;
  assert.match(stuck.problem ?? "", /stopped while passing this on/);
  assert.equal(stuck.isWorking, false);
});

test("the agent's side is checked before it is kept", () => {
  assert.equal(parseAgentSide({ messages: "no", isWorking: true, activity: null }, 0), null);
  assert.equal(parseAgentSide({ messages: [{ id: "a", text: "x", at: "soon" }], isWorking: true, activity: null }, 0), null);
  assert.equal(parseAgentSide({ messages: [], isWorking: "yes", activity: null }, 0), null);
  assert.deepEqual(parseAgentSide({ messages: [], isWorking: false, activity: null, thread: { host: 1 } }, 5),
    { messages: [], isWorking: false, activity: null, thread: null, updatedAt: 5 });
});

test("the list says why the builder is offline: the runner's Mac, or a runner gone quiet", async () => {
  const store = memoryStore();
  assert.deepEqual((await feedbackList(store, 1_000)).builderStatus,
    { online: false, lastPollAt: null, detail: "The runner has never polled." });
  await runnerPoll(store, false, 1_000, "orca worktree ps: Could not connect to the remote Orca runtime");
  assert.deepEqual((await feedbackList(store, 2_000)).builderStatus, {
    online: false, lastPollAt: new Date(1_000).toISOString(),
    detail: "orca worktree ps: Could not connect to the remote Orca runtime",
  });
  await runnerPoll(store, true, 3_000, "ignored when Orca answers");
  assert.deepEqual((await feedbackList(store, 4_000)).builderStatus,
    { online: true, lastPollAt: new Date(3_000).toISOString(), detail: null });
  assert.equal(builderStatusOf({ at: 3_000, orca: true }, 3_000 + 120_000).detail, "The runner has not polled for 120 s.");
  await runnerPoll(store, false, 5_000, "x".repeat(500));
  assert.equal((await feedbackList(store, 5_000)).builderStatus.detail?.length, 200);
});

test("a list read logs what the app was told about the builder", () => {
  const line = JSON.parse(listServedLog(
    { online: false, lastPollAt: new Date(1_000).toISOString(), detail: "Orca down" }, 2, 31_000,
  ));
  assert.deepEqual(line, {
    event: "feedback_list_served", builderOnline: false, runnerPollAgeSeconds: 30, detail: "Orca down", threads: 2,
  });
});
