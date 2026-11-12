// Writes PRHub's design from DESIGN.md's tokens, so a font, colour, size, corner or icon style is one line there:
// - a colour set per colour token, light and dark (`ink` and `ink-dark`), in app/PRHub/Assets.xcassets, and
//   AccentColor from `primary`;
// - PRKit/Sources/PRKitDesign/DesignTokens.swift: type, spacing, corners, motion and icon style.
// Run `make -C app design` after editing DESIGN.md. `--check` changes nothing and fails if the outputs are stale.
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../../..");
const assets = join(repo, "app/PRHub/Assets.xcassets");
const swiftOut = join(repo, "PRKit/Sources/PRKitDesign/DesignTokens.swift");
const check = process.argv.includes("--check");

const text = readFileSync(join(repo, "DESIGN.md"), "utf8");
const front = text.match(/^---\n([\s\S]*?)\n---\n/);
if (!front) fail("DESIGN.md has no token front matter");
const tokens = parse(front[1]);

/** Every file this run writes, path to contents; compared or written at the end. */
const outputs = new Map();
const stale = [];

// Colours ----------------------------------------------------------------------------------------------------------
const colors = tokens.colors ?? {};
if (!colors.primary) fail("colors.primary is required: it is the accent");
const generatedSets = new Set();
for (const [name, value] of Object.entries(colors)) {
  if (name.endsWith("-dark")) {
    if (!(name.slice(0, -5) in colors)) fail(`colors.${name} has no light colour ${name.slice(0, -5)}`);
    continue;
  }
  const setName = name === "primary" ? "AccentColor" : pascal(name);
  colorSet(setName, value, colors[`${name}-dark`]);
}
if (tokens["x-themes"]) fail("x-themes is not used here: PRHub has one accent, colors.primary");
// A colour set this generator made before whose token is gone is stale; hand-made sets are left alone.
for (const entry of readdirSync(assets)) {
  if (!entry.endsWith(".colorset")) continue;
  const contents = readFileSync(join(assets, entry, "Contents.json"), "utf8");
  if (contents.includes('"generated-by" : "DESIGN.md"') && !generatedSets.has(entry.replace(".colorset", ""))) {
    stale.push(`${entry} is no longer in DESIGN.md: delete it`);
  }
}

function colorSet(setName, light, dark) {
  generatedSets.add(setName);
  const entry = (value, appearance) => ({
    ...(appearance ? { appearances: [{ appearance: "luminosity", value: appearance }] } : {}),
    color: { "color-space": "srgb", components: rgba(value) },
    idiom: "universal",
  });
  const json = {
    colors: [entry(light), ...(dark ? [entry(dark, "dark")] : [])],
    info: { author: "xcode", version: 1 },
    properties: { "generated-by": "DESIGN.md" },
  };
  outputs.set(join(assets, `${setName}.colorset`, "Contents.json"), xcodeJSON(json));
}

function rgba(value) {
  const hex = String(value).trim().match(/^#([0-9a-f]{6})([0-9a-f]{2})?$/i);
  if (!hex) fail(`colour ${value} must be #RRGGBB or #RRGGBBAA`);
  const byte = (at) => `0x${hex[1].slice(at, at + 2).toUpperCase()}`;
  const alpha = hex[2] ? (parseInt(hex[2], 16) / 255).toFixed(3) : "1.000";
  return { alpha, blue: byte(4), green: byte(2), red: byte(0) };
}

// Type, space, corners, icons ----------------------------------------------------------------------------------------
const STYLES = {
  "large-title": "largeTitle", title: "title", title2: "title2", title3: "title3", headline: "headline",
  subheadline: "subheadline", body: "body", callout: "callout", footnote: "footnote", caption: "caption",
  caption2: "caption2",
};
const WEIGHTS = { 100: "ultraLight", 200: "thin", 300: "light", 400: "regular", 500: "medium", 600: "semibold",
  700: "bold", 800: "heavy", 900: "black" };
const typography = tokens.typography ?? {};
const styleLines = [];
const families = new Set();
for (const [token, style] of Object.entries(STYLES)) {
  const type = typography[token];
  if (!type) fail(`typography.${token} is required: AppFont has a style for it`);
  families.add(type.fontFamily);
  styleLines.push(`        .${style}: Style(size: ${points(type.fontSize)}, weight: .${weight(type.fontWeight)}),`);
}
if (families.size !== 1) fail(`every text style must share one fontFamily, found ${[...families].join(", ")}`);
const code = typography.code;
if (!code) fail("typography.code is required: diffs and code use it");
const macTypography = tokens["x-mac-typography"] ?? {};
const macStyleLines = [];
for (const [token, style] of Object.entries(STYLES)) {
  if (!macTypography[token]) fail(`x-mac-typography.${token} is required: the Mac has a size for every style`);
  const type = typography[token];
  macStyleLines.push(
    `        .${style}: Style(size: ${points(macTypography[token])}, weight: .${weight(type.fontWeight)}),`);
}
if (!macTypography.code) fail("x-mac-typography.code is required: diffs and code on the Mac use it");

const space = Object.entries(tokens.spacing ?? {}).map(([name, value]) => `    public static let ${camel(name)}: CGFloat = ${points(value)}`);
const radius = Object.entries(tokens.rounded ?? {}).map(([name, value]) => `    public static let ${camel(name)}: CGFloat = ${points(value)}`);
const motion = Object.entries(tokens["x-motion"] ?? {}).map(([name, value]) => `    public static let ${camel(name)}: Double = ${seconds(value)}`);
if (motion.length === 0) fail("x-motion is required: AppMotion's durations come from it");
const icons = tokens["x-icons"] ?? {};
const VARIANTS = { none: ".none", fill: ".fill", circle: ".circle", "circle-fill": ".circle.fill", square: ".square",
  "square-fill": ".square.fill" };
if (!(icons.variant in VARIANTS)) fail(`x-icons.variant must be one of ${Object.keys(VARIANTS).join(", ")}`);

const swift = `// Generated from DESIGN.md by app/Tools/design/generate.mjs. Do not edit: change DESIGN.md and run make -C app design.
// swiftlint:disable all
import SwiftUI

/// DESIGN.md's tokens. Colours are the asset catalogue's colour sets, written by the same run.
public enum DesignTokens {
    /// Every text style's family; \`nil\` is the system font.
    public static let fontFamily: String? = ${family(typography.body.fontFamily)}
    /// Code and diffs; \`nil\` is the system's monospaced font.
    public static let codeFontFamily: String? = ${family(code.fontFamily)}
    public static let codeFontSize: CGFloat = ${points(code.fontSize)}

    public struct Style: Sendable {
        public let size: CGFloat
        public let weight: Font.Weight

        public init(size: CGFloat, weight: Font.Weight) {
            self.size = size
            self.weight = weight
        }
    }

    /// Each Dynamic Type style at the default text size.
    public static let styles: [Font.TextStyle: Style] = [
${styleLines.join("\n")}
    ]

    /// Each style on the Mac at Actual Size (\`x-mac-typography\`).
    public static let macStyles: [Font.TextStyle: Style] = [
${macStyleLines.join("\n")}
    ]
    public static let macCodeFontSize: CGFloat = ${points(macTypography.code)}

    /// Applied to every SF Symbol from the app's root.
    public static let iconVariant: SymbolVariants = ${VARIANTS[icons.variant]}
}

/// Space between and around things (DESIGN.md \`spacing\`).
public enum Space {
${space.join("\n")}
}

/// Corners (DESIGN.md \`rounded\`).
public enum Radius {
${radius.join("\n")}
}

/// How long things take to move, in seconds (DESIGN.md \`x-motion\`). \`AppMotion\` is drawn from these.
public enum MotionTokens {
${motion.join("\n")}
}
`;
outputs.set(swiftOut, swift);

function family(name) {
  return name === "system" || name === "system-mono" ? "nil" : JSON.stringify(name);
}
function points(value) {
  const match = String(value).match(/^(\d+(?:\.\d+)?)px$/);
  if (!match) fail(`${value} must be in px (points)`);
  return Number(match[1]);
}
function seconds(value) {
  const match = String(value).match(/^(\d+)ms$/);
  if (!match) fail(`${value} must be in ms`);
  return Number(match[1]) / 1000;
}
function weight(value) {
  const name = WEIGHTS[Number(value)];
  if (!name) fail(`font weight ${value} must be 100 to 900 in hundreds`);
  return name;
}
function pascal(name) {
  return name.split("-").map((part) => part[0].toUpperCase() + part.slice(1)).join("");
}
function camel(name) {
  const p = pascal(name);
  return p[0].toLowerCase() + p.slice(1);
}
/** Xcode's own JSON layout, so a generated file and one Xcode rewrites don't differ. */
function xcodeJSON(value) {
  return `${JSON.stringify(sortKeys(value), null, 2).replace(/": /g, '" : ')}\n`;
}
function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortKeys(value[key])]));
  }
  return value;
}
function fail(message) {
  console.error(`DESIGN.md: ${message}`);
  process.exit(1);
}

// Write or check ------------------------------------------------------------------------------------------------------
for (const [path, contents] of outputs) {
  const current = existsSync(path) ? readFileSync(path, "utf8") : null;
  if (current === contents) continue;
  if (check) {
    stale.push(`${path.replace(`${repo}/`, "")} differs from DESIGN.md`);
  } else {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, contents);
    console.log(`wrote ${path.replace(`${repo}/`, "")}`);
  }
}
if (stale.length) {
  console.error(stale.join("\n"));
  console.error("Run make -C app design and commit the result.");
  process.exit(1);
}
