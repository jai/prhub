import assert from "node:assert/strict";
import { test } from "node:test";
import {
  addFeedback, channelStore, feedbackChat, feedbackList, type FeedbackStore, isChatChannel, listServedLog,
  parseFeedbackInput, runnerClaim, runnerPoll,
} from "../src/feedback.ts";

function memoryBucket(): FeedbackStore & { keys: () => string[] } {
  const objects = new Map<string, { body: string; etag: string }>();
  let version = 0;
  return {
    keys: () => [...objects.keys()].sort(),
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

test("the channels are feedback and finder, and nothing else", () => {
  assert.equal(isChatChannel("feedback"), true);
  assert.equal(isChatChannel("finder"), true);
  assert.equal(isChatChannel("prs"), false);
  assert.equal(isChatChannel("toString"), false);
});

test("feedback keeps its keys as they were, and finder's go under finder/", async () => {
  const bucket = memoryBucket();
  const feedback = channelStore(bucket, "feedback");
  const finder = channelStore(bucket, "finder");
  const kept = (await addFeedback(feedback, null, parseFeedbackInput({ text: "Bigger clock" })!, 1_000))!;
  const found = (await addFeedback(finder, null, parseFeedbackInput({ text: "The billing thread" })!, 2_000))!;
  await runnerPoll(feedback, true, 3_000);
  const keys = bucket.keys();
  assert.deepEqual(keys.filter((key) => key.startsWith("feedback/")).map((key) => key.replace(/\/m\/.*/, "/m/…")), [
    "feedback/chats.json", `feedback/chats/${kept}/m/…`, keys.find((key) => key.startsWith("feedback/pending/"))!,
    "feedback/runner.json",
  ]);
  assert.ok(keys.includes("finder/chats.json"));
  assert.ok(keys.some((key) => key.startsWith(`finder/chats/${found}/m/`)));
  assert.ok(keys.some((key) => key.startsWith("finder/pending/")));
  assert.equal(keys.every((key) => key.startsWith("feedback/") || key.startsWith("finder/")), true);
});

test("each channel has its own chats, queue and runner heartbeat", async () => {
  const bucket = memoryBucket();
  const feedback = channelStore(bucket, "feedback");
  const finder = channelStore(bucket, "finder");
  const kept = (await addFeedback(feedback, null, parseFeedbackInput({ text: "Bigger clock" })!, 1_000))!;
  const found = (await addFeedback(finder, null, parseFeedbackInput({ text: "The billing thread" })!, 2_000))!;

  assert.deepEqual((await feedbackList(feedback, 3_000)).threads.map(({ id }) => id), [kept]);
  assert.deepEqual((await feedbackList(finder, 3_000)).threads.map(({ id }) => id), [found]);
  assert.equal(await feedbackChat(finder, kept, 3_000), null, "a feedback chat is not on finder");
  assert.equal(await addFeedback(finder, kept, parseFeedbackInput({ text: "x" })!, 3_000), null);

  const finderWork = await runnerPoll(finder, true, 4_000);
  assert.deepEqual(finderWork.map(({ chat }) => chat), [found], "finder's runner sees only finder's queue");
  assert.equal((await feedbackList(finder, 5_000)).builderOnline, true);
  assert.equal((await feedbackList(feedback, 5_000)).builderOnline, false, "finder's poll is not feedback's heartbeat");
  assert.deepEqual(await runnerClaim(finder, kept, "m_0000000000000000", 5_000), { ok: false, status: 404 });

  const feedbackWork = await runnerPoll(feedback, false, 6_000, "Orca down");
  assert.deepEqual(feedbackWork.map(({ chat }) => chat), [kept]);
  assert.equal((await feedbackList(feedback, 7_000)).builderStatus.detail, "Orca down");
  assert.equal((await feedbackList(finder, 7_000)).builderOnline, true, "feedback's poll leaves finder's alone");
});

test("a finder list read logs as finder", () => {
  const status = { online: true, lastPollAt: new Date(1_000).toISOString(), detail: null };
  assert.equal(JSON.parse(listServedLog(status, 1, 2_000, "finder")).event, "finder_list_served");
  assert.equal(JSON.parse(listServedLog(status, 1, 2_000)).event, "feedback_list_served");
});
