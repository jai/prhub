#!/usr/bin/env node
// Publishes the newest PRHub build each TestFlight group can install, for the Workers' GET /device/config `app_latest`
// (docs/api.md) and the app's "Update available". Run every 15 minutes by .github/workflows/internal-testflight.yml:
//   node release/app-latest.mjs [--dry-run]
// It asks App Store Connect for PRHub's processed, unexpired builds: `internal` is the newest internal testers can
// install (every build, as release builds go to the Internal group too), `public` the newest external testers can
// (the Public group, once Beta App Review approved it). It writes them to app-latest.json on the branch ci/app-latest,
// which the Workers read (worker/src/app-latest.ts), and only when they changed.
// Needs ASC_KEY_P8, ASC_KEY_ID and ASC_ISSUER_ID (as release/cadence.mjs), and, to write, GITHUB_TOKEN with contents
// write and GITHUB_REPOSITORY. --dry-run prints the file and writes nothing. Exits non-zero only when an API fails.
import { fileURLToPath } from "node:url";
import { client } from "./cadence.mjs";

/** PRHub's App Store Connect app (release/ship.sh). */
export const APP_ID = "6831601628";
export const BRANCH = "ci/app-latest";
export const PATH = "app-latest.json";
const AVAILABLE = "IN_BETA_TESTING";

/** PRHub's processed, unexpired builds: { version, build, internal, external }, from App Store Connect. */
export async function recentBuilds(request) {
  const query = [
    `filter[app]=${APP_ID}`, "filter[processingState]=VALID", "filter[expired]=false", "sort=-uploadedDate",
    "limit=50", "include=preReleaseVersion,buildBetaDetail", "fields[builds]=version,preReleaseVersion,buildBetaDetail",
    "fields[preReleaseVersions]=version", "fields[buildBetaDetails]=internalBuildState,externalBuildState",
  ].join("&");
  const document = await request("GET", `builds?${query}`);
  const included = new Map((document.included ?? []).map((item) => [`${item.type}/${item.id}`, item.attributes]));
  const related = (build, name) => {
    const data = build.relationships?.[name]?.data;
    return data ? included.get(`${data.type}/${data.id}`) : undefined;
  };
  return document.data.map((build) => {
    const detail = related(build, "buildBetaDetail");
    return {
      version: related(build, "preReleaseVersion")?.version ?? null,
      build: build.attributes.version,
      internal: detail?.internalBuildState === AVAILABLE,
      external: detail?.externalBuildState === AVAILABLE,
    };
  });
}

/** The newest build by number among those `group` can install: { version, build }, or undefined. */
function newestOf(builds, group) {
  return builds
    .filter((build) => build[group] && build.version && /^\d+$/.test(build.build))
    .sort((a, b) => Number(b.build) - Number(a.build))
    .map(({ version, build }) => ({ version, build }))[0];
}

/** The file's text: `{internal?, public?}`, each `{version, build}`, in a fixed order so an unchanged one is equal. */
export function latestFile(builds) {
  const internal = newestOf(builds, "internal");
  const published = newestOf(builds, "external");
  return `${JSON.stringify({ ...(internal ? { internal } : {}), ...(published ? { public: published } : {}) }, null, 2)}\n`;
}

/** A small GitHub REST client for `repository`: `github(method, path, body?)` returns the JSON, or null on a 404. */
export function githubClient({ token, repository, fetchImpl = fetch }) {
  return async function github(method, path, body) {
    const response = await fetchImpl(`https://api.github.com/repos/${repository}/${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (response.status === 404) return null;
    const text = await response.text();
    if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status} ${text}`);
    return JSON.parse(text);
  };
}

/**
 * Writes `text` to PATH on BRANCH unless it is there already. Makes the branch, with no parent, when it does not exist.
 * Returns "unchanged", "updated" or "created".
 */
export async function publish(github, text) {
  const current = await github("GET", `contents/${PATH}?ref=${encodeURIComponent(BRANCH)}`);
  if (current && Buffer.from(current.content ?? "", "base64").toString("utf8") === text) return "unchanged";
  const message = `chore(release): the newest TestFlight builds\n\n${text}`;
  if (current) {
    await github("PUT", `contents/${PATH}`, {
      message, branch: BRANCH, sha: current.sha, content: Buffer.from(text).toString("base64"),
    });
    return "updated";
  }
  const tree = await github("POST", "git/trees", { tree: [{ path: PATH, mode: "100644", type: "blob", content: text }] });
  const commit = await github("POST", "git/commits", { message, tree: tree.sha, parents: [] });
  const ref = await github("GET", `git/ref/heads/${BRANCH}`);
  if (ref) {
    await github("PATCH", `git/refs/heads/${BRANCH}`, { sha: commit.sha, force: true });
  } else {
    await github("POST", "git/refs", { ref: `refs/heads/${BRANCH}`, sha: commit.sha });
  }
  return "created";
}

async function main() {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== "--dry-run")) {
    console.error("usage: node release/app-latest.mjs [--dry-run]");
    process.exit(2);
  }
  const dryRun = args.includes("--dry-run");
  const needed = ["ASC_KEY_P8", "ASC_KEY_ID", "ASC_ISSUER_ID", ...(dryRun ? [] : ["GITHUB_TOKEN", "GITHUB_REPOSITORY"])];
  for (const name of needed) {
    if (!process.env[name]) {
      console.error(`${name} is not set`);
      process.exit(2);
    }
  }
  const request = client({
    keyPEM: process.env.ASC_KEY_P8, keyID: process.env.ASC_KEY_ID, issuerID: process.env.ASC_ISSUER_ID,
  });
  const text = latestFile(await recentBuilds(request));
  if (dryRun) {
    process.stdout.write(text);
    return;
  }
  const github = githubClient({ token: process.env.GITHUB_TOKEN, repository: process.env.GITHUB_REPOSITORY });
  console.log(`${await publish(github, text)}: ${JSON.stringify(JSON.parse(text))}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
