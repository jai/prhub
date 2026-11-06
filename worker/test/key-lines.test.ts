import assert from "node:assert/strict";
import { test } from "node:test";
import { contextOf, inputFor, isGenerated, keepReal, type KeyLine, parseDiff, replaceDescription } from "../src/key-lines.ts";

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
  assert.deepEqual(file.marked.slice(1), ["R10 const one = 1;", "L11-const two = 2;", "R11+const two = 3;", "R12 const three = 3;"]);
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
  const item = (path: string, line: number, side: KeyLine["side"]): KeyLine =>
    ({ path, line, side, kind: "risk", why: "Check this." });
  const kept = keepReal([item("src/a.ts", 11, "RIGHT"), item("src/a.ts", 11, "RIGHT"), item("src/a.ts", 99, "RIGHT"),
    item("nope.ts", 1, "RIGHT"), item("gone.ts", 1, "LEFT"), item("gone.ts", 1, "RIGHT")], files);
  assert.deepEqual(kept.map(({ path, line }) => `${path}:${line}`), ["src/a.ts:11", "gone.ts:1"]);
});

test("generated files stay out", () => {
  assert.ok(isGenerated("package-lock.json"));
  assert.ok(isGenerated("web/dist/app.js"));
  assert.ok(!isGenerated("src/build.ts"));
});

test("a rewrite replaces the Description section and nothing else", () => {
  const body = "## Checklist\n- [x] one\n\n## Description\nOld words\n\n## AI Assistance\nkept";
  assert.equal(replaceDescription(body, "New words"), "## Checklist\n- [x] one\n\n## Description\nNew words\n\n## AI Assistance\nkept");
  assert.equal(replaceDescription("plain body", "New words"), "New words");
});
