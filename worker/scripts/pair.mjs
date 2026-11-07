#!/usr/bin/env node
// Mints a one-time pairing code for PRHub, the PR app (docs/api.md): puts `pair/<sha256(code)>.json` in the
// Worker's R2 bucket and prints the setup link the app opens, plus a QR code when `qrencode` is installed. The app then
// calls POST /device/pair with the code and its own device secret, and the Worker admits it. The code works once and
// lasts 30 minutes.
//
//   npm run pair -- --worker https://<worker>.<subdomain>.workers.dev [--app "<label>"] [--config <wrangler config>]
//
// Without --app the code makes the phone this Worker's one device, replacing any paired before it; with --app it adds
// another (an iPad, a Mac). Needs CLOUDFLARE_API_TOKEN (and CLOUDFLARE_ACCOUNT_ID unless the config names the account).

import { createHash, randomInt } from "node:crypto";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

/** PRHub's URL scheme (bundle id com.jaigovindani.prreview). */
const SCHEME = "prhub";
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const TTL_SECONDS = 1800;
const LABEL_MAX = 64;

const args = parseArgs(process.argv.slice(2));
if (args === null || args.worker === undefined) {
  console.error('usage: npm run pair -- --worker <https://worker url> [--app "<label>"] [--config <wrangler config>]');
  process.exit(2);
}
const worker = args.worker.replace(/\/+$/, "");
if (!/^https:\/\/[^\s/]+$/.test(worker)) {
  console.error(`refusing ${JSON.stringify(args.worker)}: the Worker URL is https://<host>, nothing after it.`);
  process.exit(2);
}
if (args.app !== undefined && (args.app.length === 0 || args.app.length > LABEL_MAX)) {
  console.error(`refusing label ${JSON.stringify(args.app)}: a label is 1-${LABEL_MAX} characters.`);
  process.exit(2);
}
if (!process.env.CLOUDFLARE_API_TOKEN) {
  console.error("CLOUDFLARE_API_TOKEN is not set.");
  process.exit(2);
}
const configPath = args.config ?? "wrangler.jsonc";
const bucket = bucketOf(configPath);

const code = Array.from({ length: 8 }, () => ALPHABET[randomInt(ALPHABET.length)]).join("");
const now = new Date();
const record = {
  role: args.app === undefined ? "device" : "app",
  label: args.app ?? null,
  created_at: now.toISOString(),
  expires_at: new Date(now.getTime() + TTL_SECONDS * 1000).toISOString(),
};
const key = `pair/${createHash("sha256").update(code, "utf8").digest("hex")}.json`;
const put = spawnSync("npx", ["--yes", "wrangler@4", "r2", "object", "put", `${bucket}/${key}`, "--pipe", "--remote",
  "--content-type", "application/json", "--config", configPath], {
  input: JSON.stringify(record), stdio: ["pipe", "ignore", "inherit"],
});
if (put.error || put.status !== 0) {
  console.error(`could not write the pairing code to R2 bucket ${bucket}${put.error ? `: ${put.error.message}` : ""}`);
  process.exit(1);
}

const link = `${SCHEME}://setup?worker=${encodeURIComponent(worker)}&code=${code}`;
console.log("");
console.log(`Pairing code ${code.slice(0, 4)}-${code.slice(4)} (${record.role}${record.label ? `, "${record.label}"` : ""}),`);
console.log(`single use, valid until ${record.expires_at}. Open this link on the iPhone, or scan the QR code:`);
console.log("");
console.log(link);
console.log("");
const qr = spawnSync("qrencode", ["-t", "ANSIUTF8", link], { stdio: ["ignore", "inherit", "ignore"] });
if (qr.error || qr.status !== 0) console.log("(Install qrencode to print a QR code here: brew install qrencode.)");

/** The R2 bucket bound as DIFFS, read from the wrangler config. Comments in it are whole lines. */
function bucketOf(path) {
  let config;
  try {
    const text = readFileSync(path, "utf8").split("\n").filter((line) => !line.trim().startsWith("//")).join("\n");
    config = JSON.parse(text.replace(/,(\s*[}\]])/g, "$1"));
  } catch (error) {
    console.error(`could not read ${path}: ${error.message}`);
    process.exit(2);
  }
  const name = (config.r2_buckets ?? []).find((binding) => binding.binding === "DIFFS")?.bucket_name;
  if (!name) {
    console.error(`${path} binds no R2 bucket as DIFFS.`);
    process.exit(2);
  }
  return name;
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (value === undefined) return null;
    if (flag === "--worker") out.worker = value;
    else if (flag === "--app") out.app = value;
    else if (flag === "--config") out.config = value;
    else return null;
  }
  return out;
}
