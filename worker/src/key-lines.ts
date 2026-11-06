/** The diff as the model reads it, and the checks on what comes back. Nothing here calls anything. */

export type Side = "LEFT" | "RIGHT";

export interface DiffFile {
  path: string;
  /** The hunks, each line marked `R120` or `L88`, so an answer can name a line exactly. */
  marked: string[];
  newLines: Set<number>;
  oldLines: Set<number>;
  /** First and last new-side line of each hunk. */
  ranges: [number, number][];
}

export interface KeyLine {
  path: string;
  line: number;
  side: Side;
  kind: "decision" | "risk" | "logic";
  why: string;
}

/** Past this many characters of input, about 200,000 tokens, the rest of the files are named as left out. */
export const MAX_INPUT_CHARS = 800_000;
/** The default context: this many lines either side of a change. */
export const DEFAULT_CONTEXT = 100;
const MAX_ITEMS = 10;

const GENERATED = [
  /(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Cargo\.lock|composer\.lock|Gemfile\.lock|go\.sum)$/,
  /(^|\/)(dist|build|vendor|node_modules|generated|__snapshots__)\//,
  /\.(min\.js|min\.css|map|snap|lock|pb\.go)$/,
  /\.(png|jpe?g|gif|webp|ico|pdf|zip|gz|woff2?|ttf|mp4|mov)$/i,
];

export function isGenerated(path: string): boolean {
  return GENERATED.some((pattern) => pattern.test(path));
}

function pathOf(section: string): string | null {
  const target = /^\+\+\+ b\/(.+)$/m.exec(section)?.[1] ?? /^rename to (.+)$/m.exec(section)?.[1]
    ?? /^--- a\/(.+)$/m.exec(section)?.[1];
  return target ?? null;
}

export function parseDiff(diff: string): DiffFile[] {
  return diff.split(/^diff --git /m).slice(1).flatMap((section) => {
    const path = pathOf(section);
    if (!path) {
      return [];
    }
    const file: DiffFile = { path, marked: [], newLines: new Set(), oldLines: new Set(), ranges: [] };
    let oldLine = 0;
    let newLine = 0;
    let isInHunk = false;
    for (const line of section.split("\n")) {
      const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,(\d+))? @@/.exec(line);
      if (hunk) {
        oldLine = Number(hunk[1]);
        newLine = Number(hunk[2]);
        isInHunk = true;
        file.ranges.push([newLine, newLine + Math.max(Number(hunk[3] ?? 1) - 1, 0)]);
        file.marked.push(line);
      } else if (isInHunk && line.startsWith("+")) {
        file.newLines.add(newLine);
        file.marked.push(`R${newLine}${line}`);
        newLine += 1;
      } else if (isInHunk && line.startsWith("-")) {
        file.oldLines.add(oldLine);
        file.marked.push(`L${oldLine}${line}`);
        oldLine += 1;
      } else if (isInHunk && line.startsWith(" ")) {
        file.newLines.add(newLine);
        file.oldLines.add(oldLine);
        file.marked.push(`R${newLine}${line}`);
        oldLine += 1;
        newLine += 1;
      }
    }
    return file.marked.length > 0 ? [file] : [];
  });
}

/** `contextLines` lines either side of each hunk, numbered; -1 is the whole file. */
export function contextOf(source: string, file: DiffFile, contextLines: number): string {
  const lines = source.split("\n");
  const windows = contextLines < 0
    ? [[1, lines.length]]
    : file.ranges.map(([first, last]) => [Math.max(first - contextLines, 1), Math.min(last + contextLines, lines.length)]);
  const merged: number[][] = [];
  for (const [first, last] of windows.sort((a, b) => a[0] - b[0])) {
    const previous = merged.at(-1);
    if (previous && first <= previous[1] + 1) {
      previous[1] = Math.max(previous[1], last);
    } else {
      merged.push([first, last]);
    }
  }
  return merged
    .map(([first, last]) => lines.slice(first - 1, last).map((text, index) => `${first + index}: ${text}`).join("\n"))
    .join("\n...\n");
}

/** Every file that fits, whole, and the names of those that don't: a file is never cut off part way. */
export function inputFor(
  files: DiffFile[], sources: Map<string, string>, contextLines: number,
): { input: string; leftOut: string[] } {
  const blocks: string[] = [];
  const leftOut: string[] = [];
  let size = 0;
  for (const file of files) {
    const source = sources.get(file.path);
    const code = contextLines !== 0 && source !== undefined
      ? `\n<code>\n${contextOf(source, file, contextLines)}\n</code>` : "";
    const block = `<file path=${JSON.stringify(file.path)}>\n<diff>\n${file.marked.join("\n")}\n</diff>${code}\n</file>`;
    if (size + block.length > MAX_INPUT_CHARS) {
      leftOut.push(file.path);
    } else {
      blocks.push(block);
      size += block.length;
    }
  }
  return { input: blocks.join("\n"), leftOut };
}

/** Only lines the diff really shows, so a tap can always land. The model's word is not enough for that. */
export function keepReal(items: KeyLine[], files: DiffFile[]): KeyLine[] {
  const byPath = new Map(files.map((file) => [file.path, file]));
  const seen = new Set<string>();
  return items.filter(({ path, line, side, why }) => {
    const file = byPath.get(path);
    const key = `${path}:${side}:${line}`;
    const isShown = (side === "RIGHT" ? file?.newLines : file?.oldLines)?.has(line) ?? false;
    if (!isShown || !why.trim() || seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  }).slice(0, MAX_ITEMS);
}

/** The body with its `## Description` section's words replaced. A body with no such heading is all description. */
export function replaceDescription(body: string, description: string): string {
  const heading = /^## Description[^\n]*\n/m.exec(body);
  if (!heading) {
    return description;
  }
  const start = heading.index + heading[0].length;
  const rest = body.slice(start);
  const next = /^## /m.exec(rest);
  return `${body.slice(0, start)}${description.trim()}\n\n${next ? rest.slice(next.index) : ""}`.trimEnd();
}
