#!/usr/bin/env node
// Confirms that Xcode Cloud started a run for a release tag, and pushes the tag again when it did not. The `release`
// job of .github/workflows/release.yml runs it between pushing the ios-v tag and making the GitHub Release:
//   node release/confirm-xcode-cloud-run.mjs <tag> [--dry-run]
// Why: Xcode Cloud starts on GitHub's event for the tag, and some of those events never reach it (jai/ci,
// docs/xcode-cloud-start). A tag that is deleted and pushed again makes a new event.
//
// The contract:
// - It exits 0 only when Xcode Cloud has a run for the tag. A run that is there already is enough, so running it again
//   for the same tag pushes nothing.
// - It looks every INTERVAL seconds for PATIENCE seconds. With no run by then, it deletes the tag on origin and pushes
//   the same tag object again, at most REPUSHES times, and waits as long after each. Still no run: it exits 1 and says
//   what to do.
// - It pushes again only after App Store Connect answered "no run". A look that fails is tried again; when the last
//   look of a wait fails, it exits 1 and has pushed nothing.
// - It deletes the tag only while origin's tag is the object this checkout has, so a tag someone moved is left alone.
// - --dry-run looks once, waits for nothing and pushes nothing. It prints what it found and what it would do.
// Needs ASC_KEY_P8 (the .p8 key's PEM text), ASC_KEY_ID and ASC_ISSUER_ID, and a checkout whose `origin` may push tags.
import { execFileSync } from "node:child_process";
import { setTimeout as wait } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { APP_ID, client } from "./app-latest.mjs";

/** How long Xcode Cloud gets to start a run after a push, in seconds. It starts within a minute when it starts. */
export const PATIENCE = 180;
/** The seconds between two looks. */
export const INTERVAL = 15;
/** How many times the tag is pushed again. */
export const REPUSHES = 2;

/** Xcode Cloud's newest run for the tag named `tag`: { number, created }, or undefined when it has none. */
export async function runFor(request, tag) {
  const product = await request("GET", `apps/${APP_ID}/ciProduct?fields[ciProducts]=name`);
  const query = [
    "sort=-number", "limit=25", "include=sourceBranchOrTag", "fields[ciBuildRuns]=number,createdDate,sourceBranchOrTag",
    "fields[scmGitReferences]=name,kind",
  ].join("&");
  const runs = await request("GET", `ciProducts/${product.data.id}/buildRuns?${query}`);
  const tags = new Set(
    (runs.included ?? [])
      .filter((ref) => ref.type === "scmGitReferences" && ref.attributes.kind === "TAG" && ref.attributes.name === tag)
      .map((ref) => ref.id),
  );
  const run = runs.data.find((candidate) => tags.has(candidate.relationships?.sourceBranchOrTag?.data?.id));
  return run && { number: run.attributes.number, created: run.attributes.createdDate };
}

/** Looks `looks` times, INTERVAL apart, and returns the run once there is one. Throws when the last look failed. */
async function awaitRun({ find, sleep, log, looks }) {
  for (let look = 1; look <= looks; look += 1) {
    try {
      const run = await find();
      if (run) return run;
    } catch (error) {
      if (look === looks) throw new Error(`App Store Connect did not answer, so nothing was pushed again: ${error.message}`);
      log(`App Store Connect did not answer (${error.message}). Looking again.`);
    }
    if (look < looks) await sleep(INTERVAL);
  }
  return undefined;
}

/**
 * The run Xcode Cloud started for `tag`, after pushing the tag again when it started none (the contract is at the top).
 * `find()` is the run or undefined, `repush()` deletes and pushes the tag, `sleep(seconds)` waits. Throws when there is
 * no run in the end.
 */
export async function confirm({ tag, find, repush, sleep, log = console.log, dryRun = false }) {
  const ref = `refs/tags/${tag}`;
  for (let pushes = 0; ; pushes += 1) {
    const run = await awaitRun({ find, sleep, log, looks: dryRun ? 1 : PATIENCE / INTERVAL + 1 });
    if (run) {
      log(`Xcode Cloud run #${run.number} is for ${tag} (created ${run.created}).`);
      return run;
    }
    if (dryRun) {
      throw new Error(
        `Xcode Cloud has no run for ${tag}. Dry run: nothing was pushed. Without --dry-run this waits ${PATIENCE} s, ` +
          `then deletes ${ref} on origin and pushes it again, at most ${REPUSHES} times.`,
      );
    }
    if (pushes === REPUSHES) {
      throw new Error(
        `Xcode Cloud started no run for ${tag}: the tag was pushed ${pushes + 1} times and each got ${PATIENCE} s. ` +
          `The tag is on GitHub; the GitHub Release is not made. What to do: in App Store Connect, open the app's ` +
          `Xcode Cloud tab and check that its workflow still starts on this tag and that its GitHub connection works. ` +
          `Then re-run this job: it looks again, pushes the tag again if there is still no run, and makes the Release ` +
          `once there is one.`,
      );
    }
    log(`No Xcode Cloud run for ${tag} after ${PATIENCE} s. Pushing the tag again (${pushes + 1} of ${REPUSHES}).`);
    await repush();
  }
}

/**
 * Deletes `tag` on origin and pushes the same tag object again, from the git checkout at `cwd`. The delete goes through
 * only while origin's tag is this checkout's object.
 */
export function repushTag(tag, { cwd = process.cwd() } = {}) {
  const git = (...args) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();
  const ref = `refs/tags/${tag}`;
  const object = git("rev-parse", "--verify", ref);
  git("push", `--force-with-lease=${ref}:${object}`, "origin", `:${ref}`);
  git("push", "origin", ref);
}

async function main() {
  const args = process.argv.slice(2);
  const tags = args.filter((arg) => arg !== "--dry-run");
  if (tags.length !== 1 || tags[0].startsWith("-")) {
    console.error("usage: node release/confirm-xcode-cloud-run.mjs <tag> [--dry-run]");
    process.exit(2);
  }
  for (const name of ["ASC_KEY_P8", "ASC_KEY_ID", "ASC_ISSUER_ID"]) {
    if (!process.env[name]) {
      console.error(`${name} is not set`);
      process.exit(2);
    }
  }
  const [tag] = tags;
  const request = client({
    keyPEM: process.env.ASC_KEY_P8, keyID: process.env.ASC_KEY_ID, issuerID: process.env.ASC_ISSUER_ID,
  });
  await confirm({
    tag,
    find: () => runFor(request, tag),
    repush: () => repushTag(tag),
    sleep: (seconds) => wait(seconds * 1000),
    dryRun: args.includes("--dry-run"),
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((error) => {
    // In a workflow, the message is also the run's error annotation.
    console.error(process.env.GITHUB_ACTIONS ? `::error title=No Xcode Cloud run::${error.message}` : error.message);
    process.exit(1);
  });
}
