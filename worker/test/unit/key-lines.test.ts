import assert from "node:assert/strict";
import { test } from "vitest";
import {
  contextOf,
  inputFor,
  isGenerated,
  keepReal,
  type KeyLine,
  parseDiff,
  replaceDescription,
  writtenDescription,
} from "../../src/key-lines.ts";
import { finnPrBody } from "../support/pr-node.ts";

const diff = `diff --git a/src/a.ts b/src/a.ts
index 1..2 100644
--- a/src/a.ts
+++ b/src/a.ts
@@ -10,3 +10,3 @@ function a() {
 const one = 1;
-const two = 2;
+const two = 3;
 const three = 3;
diff --git a/gone.ts b/gone.ts
deleted file mode 100644
--- a/gone.ts
+++ /dev/null
@@ -1,1 +0,0 @@
-bye
`;

test("each diff line is marked with its place", () => {
  const [file, gone] = parseDiff(diff);
  assert.equal(file.path, "src/a.ts");
  assert.deepEqual(file.marked.slice(1), [
    "R10 const one = 1;",
    "L11-const two = 2;",
    "R11+const two = 3;",
    "R12 const three = 3;",
  ]);
  assert.deepEqual([...file.newLines], [10, 11, 12]);
  assert.deepEqual(file.ranges, [[10, 12]]);
  assert.equal(gone.path, "gone.ts");
  assert.deepEqual([...gone.oldLines], [1]);
});

test("context is X lines either side, and -1 is the whole file", () => {
  const [file] = parseDiff(diff);
  const source = Array.from({ length: 30 }, (_, index) => `line ${index + 1}`).join("\n");
  const two = contextOf(source, file, 2).split("\n");
  assert.equal(two[0], "8: line 8");
  assert.equal(two.at(-1), "14: line 14");
  assert.equal(contextOf(source, file, -1).split("\n").length, 30);
});

test("0 sends the diff alone, and what doesn't fit is named, never cut", () => {
  const files = parseDiff(diff);
  const sources = new Map([["src/a.ts", "x\n".repeat(20)]]);
  assert.ok(!inputFor(files, sources, 0).input.includes("<code>"));
  assert.ok(inputFor(files, sources, 5).input.includes("<code>"));
  const huge = new Map([["src/a.ts", "x\n".repeat(900_000)]]);
  const { input, leftOut } = inputFor(files, huge, -1);
  assert.deepEqual(leftOut, ["src/a.ts"]);
  assert.ok(input.includes("gone.ts"));
});

test("a line the diff doesn't show is dropped, however sure the model is", () => {
  const files = parseDiff(diff);
  const item = (path: string, line: number, side: KeyLine["side"]): KeyLine => ({
    path,
    line,
    side,
    kind: "risk",
    why: "Check this.",
  });
  const kept = keepReal(
    [
      item("src/a.ts", 11, "RIGHT"),
      item("src/a.ts", 11, "RIGHT"),
      item("src/a.ts", 99, "RIGHT"),
      item("nope.ts", 1, "RIGHT"),
      item("gone.ts", 1, "LEFT"),
      item("gone.ts", 1, "RIGHT"),
    ],
    files,
  );
  assert.deepEqual(
    kept.map(({ path, line }) => `${path}:${line}`),
    ["src/a.ts:11", "gone.ts:1"],
  );
});

test("generated files stay out", () => {
  assert.ok(isGenerated("package-lock.json"));
  assert.ok(isGenerated("web/dist/app.js"));
  assert.ok(!isGenerated("src/build.ts"));
});

test("a rewrite replaces the Description section and nothing else", () => {
  const body = "## Checklist\n- [x] one\n\n## Description\nOld words\n\n## AI Assistance\nkept";
  assert.equal(
    replaceDescription(body, "New words"),
    "## Checklist\n- [x] one\n\n## Description\nNew words\n\n## AI Assistance\nkept",
  );
  assert.equal(replaceDescription("plain body", "New words"), "New words");
});

const PLAIN =
  "Statements from the new bank layout parse again: the parser reads the moved date column.";
const SLOP = "This PR makes the parser robust and seamless, a comprehensive fix for every layout.";

test("the AI slop check reads only the author's words: not the checklist, not the AI trace", () => {
  const written = writtenDescription(finnPrBody(PLAIN));
  assert.ok(written.startsWith("## Description"), "the checklist's checkboxes are left out");
  assert.doesNotMatch(written, /I have provided|- \[x\]/);
  assert.match(written, /the parser reads the moved date column/);
  assert.match(written, /### Plan/, "headings in the author's part are kept as they are");
  assert.doesNotMatch(
    written,
    /AI Assistance|Workflow trace|💬|🛠️|✅|AGENTS\.repo\.md/,
    "the AI trace is left out",
  );
});

test("slop in the author's words still reaches the check", () => {
  assert.match(
    writtenDescription(finnPrBody(SLOP)),
    /This PR makes the parser robust and seamless/,
  );
});

test("a body without the template is all the author's words, and a trace alone leaves nothing", () => {
  assert.equal(
    writtenDescription("Fixes the retry.\n\n- [ ] a list of the author's"),
    "Fixes the retry.\n\n- [ ] a list of the author's",
  );
  assert.equal(
    writtenDescription("## AI Assistance\n\n### Workflow trace\n\n- 💬 Prompt: fix it"),
    "",
  );
});
