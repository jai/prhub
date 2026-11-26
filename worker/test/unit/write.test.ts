import assert from "node:assert/strict";
import { test } from "vitest";
import { gitHubReason, parseWrite, refusalWords, toggleTask } from "../../src/write-input.ts";

test("an approval needs no words, every other write does", () => {
  assert.deepEqual(parseWrite({ kind: "review", event: "APPROVE", body: "", commit: "c" }), {
    kind: "review",
    event: "APPROVE",
    body: "",
    commit: "c",
    comments: [],
  });
  assert.equal(
    parseWrite({ kind: "review", event: "REQUEST_CHANGES", body: "", commit: "c" }),
    null,
  );
  assert.equal(parseWrite({ kind: "comment", body: "" }), null);
  assert.equal(parseWrite({ kind: "reply", body: "", thread: "t" }), null);
});

test("a line comment names its commit, file, line and side", () => {
  const line = { kind: "line", body: "b", commit: "c", path: "f", line: 3, side: "RIGHT" };
  assert.deepEqual(parseWrite(line), line);
  assert.equal(parseWrite({ ...line, side: "MIDDLE" }), null);
  assert.equal(parseWrite({ ...line, line: "3" }), null);
  assert.equal(parseWrite({ ...line, path: "" }), null);
});

test("a review may carry line comments, and they stand in for its words", () => {
  const comment = { path: "f", line: 3, side: "RIGHT", body: "b" };
  const review = { kind: "review", event: "COMMENT", body: "", commit: "c", comments: [comment] };
  assert.deepEqual(parseWrite(review), review);
  assert.equal(parseWrite({ ...review, comments: [] }), null);
  assert.equal(parseWrite({ ...review, comments: [comment, { ...comment, line: "3" }] }), null);
});

test("resolving names a thread and says which way", () => {
  assert.deepEqual(parseWrite({ kind: "resolve", thread: "t", resolved: true }), {
    kind: "resolve",
    thread: "t",
    resolved: true,
  });
  assert.equal(parseWrite({ kind: "resolve", thread: "t" }), null);
  assert.equal(parseWrite({ kind: "resolve", thread: "", resolved: false }), null);
});

test("a review must be one of GitHub's three events on a known commit", () => {
  assert.equal(parseWrite({ kind: "review", event: "MERGE", body: "x", commit: "c" }), null);
  assert.equal(parseWrite({ kind: "review", event: "APPROVE", body: "" }), null);
  assert.equal(parseWrite({ kind: "delete" }), null);
  assert.equal(parseWrite(null), null);
});

test("the PR actions take what GitHub needs and nothing else", () => {
  assert.deepEqual(parseWrite({ kind: "update_branch", commit: "abc" }), {
    kind: "update_branch",
    commit: "abc",
  });
  assert.equal(parseWrite({ kind: "update_branch" }), null);
  assert.deepEqual(parseWrite({ kind: "remove_request" }), { kind: "remove_request" });
  assert.deepEqual(parseWrite({ kind: "checkbox", index: 2, checked: true }), {
    kind: "checkbox",
    index: 2,
    checked: true,
    task: null,
  });
  assert.equal(parseWrite({ kind: "checkbox", index: 1.5, checked: true }), null);
  assert.deepEqual(parseWrite({ kind: "edit_body", body: "" }), {
    kind: "edit_body",
    body: "",
    base: null,
  });
  assert.equal(parseWrite({ kind: "edit_body" }), null);
  assert.deepEqual(parseWrite({ kind: "merge", method: "squash", commit: "abc" }), {
    kind: "merge",
    method: "squash",
    commit: "abc",
  });
  assert.equal(parseWrite({ kind: "merge", method: "force", commit: "abc" }), null);
});

test("a task is counted as the phone draws it", () => {
  const body =
    "<!-- - [ ] template -->\n- [ ] one\r\n```\n- [ ] code\n```\n  * [x] two\n<!--\n- [ ] hidden\n-->\n- [ ] three";
  assert.equal(toggleTask(body, 0, true), body.replace("- [ ] one", "- [x] one"));
  assert.equal(toggleTask(body, 1, false), body.replace("* [x] two", "* [ ] two"));
  assert.equal(toggleTask(body, 2, true), body.replace("- [ ] three", "- [x] three"));
  assert.equal(toggleTask(body, 3, true), null);
});

test("a late tap can't tick a task that has moved into its place", () => {
  const body = "- [ ] ship it\n- [ ] tell Jai";
  assert.equal(toggleTask(body, 0, true, "ship it"), "- [x] ship it\n- [ ] tell Jai");
  assert.equal(toggleTask(body, 0, true, "tell Jai"), null);
  assert.equal(toggleTask(body, 1, true, null), "- [ ] ship it\n- [x] tell Jai");
});

test("a description edit and a checkbox carry what the phone saw, when it sends it", () => {
  assert.deepEqual(parseWrite({ kind: "edit_body", body: "new", base: "old" }), {
    kind: "edit_body",
    body: "new",
    base: "old",
  });
  assert.deepEqual(parseWrite({ kind: "edit_body", body: "new" }), {
    kind: "edit_body",
    body: "new",
    base: null,
  });
  assert.deepEqual(parseWrite({ kind: "checkbox", index: 0, checked: true, task: "ship it" }), {
    kind: "checkbox",
    index: 0,
    checked: true,
    task: "ship it",
  });
});

test("a refusal without GitHub's words says what happened and what to do, never a status", () => {
  for (const status of [401, 403, 404, 409, 410, 422, 429, 500, 502, 503]) {
    const words = refusalWords(status);
    assert.doesNotMatch(words, /\d{3}/);
    assert.match(words, /\. [A-Z].*\.$/);
  }
  assert.notEqual(refusalWords(403), refusalWords(404));
  assert.notEqual(refusalWords(422), refusalWords(502));
});

test("GitHub's reason reads its errors' words, not their objects", () => {
  assert.equal(
    gitHubReason({
      message: "Validation Failed",
      errors: [
        { resource: "Issue", code: "custom", message: "Body is too long" },
        { code: "missing_field" },
        "plain",
      ],
    }),
    "Validation Failed: Body is too long: missing_field: plain",
  );
  assert.equal(gitHubReason({ message: "Not Found" }), "Not Found");
  assert.equal(gitHubReason(null), "");
});

test("a comment for the unsent review is on a line and its side, or on the whole file", () => {
  const add = {
    kind: "pending_add",
    pullRequest: "PR_1",
    body: "Check the total first.",
    path: "src/checkout/payments.ts",
    line: 12,
    side: "LEFT",
  };
  assert.deepEqual(parseWrite(add), { ...add, file: false });
  // An app that also names the commit is taken: GitHub places the thread on the PR's diff as it is.
  assert.deepEqual(parseWrite({ ...add, commit: "abc" }), { ...add, file: false });
  const { line: _line, side: _side, ...whole } = add;
  assert.deepEqual(parseWrite({ ...whole, file: true }), {
    ...whole,
    line: null,
    side: "RIGHT",
    file: true,
  });
  assert.equal(parseWrite(whole), null);
  assert.equal(parseWrite({ ...add, file: true }), null);
  assert.equal(parseWrite({ ...whole, line: 12 }), null);
  assert.equal(parseWrite({ ...add, line: 0 }), null);
  assert.equal(parseWrite({ ...add, line: 1.5 }), null);
  assert.equal(parseWrite({ ...add, side: "MIDDLE" }), null);
  assert.equal(parseWrite({ ...add, body: "" }), null);
  assert.equal(parseWrite({ ...add, path: "" }), null);
  assert.equal(parseWrite({ ...add, pullRequest: undefined }), null);
});

test("the unsent review's other writes name a thread or a comment, and sending it needs no words", () => {
  const reply = { kind: "pending_reply", thread: "PRRT_1", body: "Agreed." };
  assert.deepEqual(parseWrite(reply), reply);
  // The PR's id is not needed: the route names the PR.
  assert.deepEqual(parseWrite({ ...reply, pullRequest: "PR_1" }), reply);
  assert.equal(parseWrite({ ...reply, body: "" }), null);
  assert.equal(parseWrite({ ...reply, thread: "" }), null);
  const edit = { kind: "pending_edit", comment: "PRRC_1", body: "Check the total." };
  assert.deepEqual(parseWrite(edit), edit);
  assert.equal(parseWrite({ ...edit, body: "" }), null);
  assert.equal(parseWrite({ kind: "pending_edit", body: "Check the total." }), null);
  assert.deepEqual(parseWrite({ kind: "pending_delete", comment: "PRRC_1" }), {
    kind: "pending_delete",
    comment: "PRRC_1",
  });
  assert.equal(parseWrite({ kind: "pending_delete", comment: "" }), null);
  assert.deepEqual(parseWrite({ kind: "pending_submit", event: "COMMENT" }), {
    kind: "pending_submit",
    event: "COMMENT",
    body: "",
  });
  assert.deepEqual(parseWrite({ kind: "pending_submit", event: "APPROVE", body: "Ship it." }), {
    kind: "pending_submit",
    event: "APPROVE",
    body: "Ship it.",
  });
  assert.equal(parseWrite({ kind: "pending_submit", event: "DISMISS" }), null);
  assert.equal(parseWrite({ kind: "pending_submit" }), null);
  assert.deepEqual(parseWrite({ kind: "pending_discard" }), { kind: "pending_discard" });
  // GitHub refuses to empty an unsent review's words, so there is no write that sets them alone.
  assert.equal(parseWrite({ kind: "pending_body", pullRequest: "PR_1", body: "" }), null);
});
