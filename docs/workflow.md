# CI workflow

PRHub's CI follows Jai's personal CI standard ([personal-ci-standard.md](https://github.com/jai/skills/blob/9bb45df/jstack/skills/personal-projects/references/personal-ci-standard.md), Part 1). This file is the standard's Part 2 for this repo: what PRHub runs, where, and each deviation from Part 1 with its reason.

## Runners

- **GitHub-hosted Ubuntu** runs everything that needs no Mac: `lint-ios` and `lint-prkit` (on `ubuntu-24.04`: SwiftLint's Linux build needs libxml2.so.2), `lint-worker`, `lint-workflows`, `test-unit-worker`, `test-integration-worker`, `generate-release-candidate`, the `release` job of `release`, `deploy-worker` and `notify-update-available`. GitHub discards each VM after its job.
- **Zoomies native-Mac runners on Borg Cube 03** run the Mac work (jai/ci `hosts/borg-cube-03/zoomies-mac/kits/prhub.json`). One `mac` runner: `build-ios` and the `swift test` workflows. One `mac-desktop` runner, in the logged-in desktop session: `test-ui-ios`. Each runner is ephemeral: it takes one job, and Zoomies then deletes the runner's folder with its `_work` checkout. Jobs share the user's home folder, so anything a job writes outside `_work` stays unless the job deletes it (see "Disk use").
- Only pushes to `main`, RC tags and the clock start workflows. No workflow runs on a pull request, so no fork's code reaches the home lab.

## Components

| Component | What it is | Release tag |
| --- | --- | --- |
| `ios` | The iPhone, iPad and Mac app (`app/`). It contains PRKit. | `ios-v<version>` |
| `worker` | The Cloudflare Worker `prhub` (`worker/`, `agent/`, `deploy/hosted/`) | `worker-v<version>` |
| `prkit` | The Swift package that other apps use (`PRKit/`, `Package.swift`): PRKitCore, PRKitDesign, PRKit and FeatureKit | `v<version>` |

- `PRHubCore` in `Package.swift` is not a component. It is the app's shared logic (`app/PRHubCore`), in the package so that `swift test` can test it.
- The app contains PRKit, so a PRKit change also makes an `ios` RC, and an `ios` release runs PRKit's checks too.

## Clock

The release-clock Worker (jai/ci `worker/release-clock`, its `TARGETS` in `wrangler.jsonc`) starts `generate-release-candidate` every 3 hours (`every: 180`: 00:00, 03:00, … UTC) and `notify-update-available` every hour (minute 0), through `workflow_dispatch`.

## How a workflow reads

Each lint and test workflow has the same three parts, in this order:

1. **Prepare**: the checkout, the tools (Node, or mise for the pinned tools), the npm dependencies, and for `test-ui-ios` a Simulator of the job's own.
2. **Test** (or lint, or build): one make target, the workflow's own name. The make target is what a person runs locally.
3. **Clean up**: only what lives outside the runner's work folder. The work folder itself goes with the runner (see "Disk use").

Each test workflow runs one test layer of one component. Each push workflow runs on the paths of its component, the Makefile and its own file; lint workflows also run when their lint configuration changes.

## Test matrix

| Component | Lint | Unit | Integration | UI | Deploy |
| --- | --- | --- | --- | --- | --- |
| `ios` | `lint-ios` (with `build-ios`): push, RC | `test-unit-ios`: push, RC | `test-integration-ios`: push, RC | `test-ui-ios`: RC | Xcode Cloud: `ios-v` tag |
| `worker` | `lint-worker`: push, RC | `test-unit-worker`: push, RC | `test-integration-worker`: push, RC | | `deploy-worker`: `worker-v` tag |
| `prkit` | `lint-prkit`: push, ios and prkit RC | `test-unit-prkit`: push, ios and prkit RC | `test-integration-prkit`: push, ios and prkit RC | | None: apps get the `v` tag with Swift Package Manager |

- **Unit**: `swift test` on `PRHubUnitTests` and `PRKitUnitTests`; Vitest project `unit` in `worker/` and `agent/`. No app host, storage or network.
- **Integration**: `swift test` on `PRHubIntegrationTests` (persistence, Keychain, contract fixtures) and `PRKitIntegrationTests` (persistence, contract fixtures, bundled fonts, and the AppKit checks of `PRKit/Tests/PRKitRenderingTests`); Vitest projects `integration-node` and `integration-runtime` (workerd) in `worker/`, and `integration` in `agent/` (a real git and a local server). Outside services are stubbed.
- **UI**: `make test-ui-ios` runs two Xcode test plans on one Simulator: `PRHubRenderingTests` (rendering that needs the app host, serial, never retried), then `PRHubUITests` (what only the running app shows, in parallel on Simulator clones, each failing test run once more). Both are on an iPhone 17 and an iPad Pro 13-inch Simulator. Each plan names its full test target, so a new test class runs with no file change.
- **End-to-end**: `PRHubE2ETests.xctestplan` and `PRHubE2EPairingTests.xctestplan` need a paired deployed Worker; a person runs them. Tester Army (`e2e/`) is started by hand.
- **Not tests**: `PRHubScreenshots.xctestplan` captures every screen for review and the App Store, and asserts nothing. Only `make screenshots-ios` runs it. `PRHubPerformanceTests.xctestplan` needs a physical device.
- `deploy-worker` deploys with `wrangler deploy` (`deploy/hosted/wrangler.jsonc`) and then checks that the live Worker answers. Xcode Cloud's "PRHub TestFlight Internal and External" starts on the `ios-v` tag and only archives and uploads; `app/ci_scripts/ci_post_clone.sh` generates the project for it.
- This repo is public. Each `lint-<component>` runs gitleaks on its component's files.

## Release order

`release` runs the checks of the RC's component in its own run, cheapest first. Lint and unit tests start together; each integration workflow waits for its unit tests; `test-ui-ios` waits for every other `ios` and `prkit` check, so a long Simulator run never takes the Mac for a commit that a cheaper check already failed. Only each component's first jobs check the tag: a job that needs a skipped job is skipped too. The `release` job runs when no check failed or was cancelled.

## Make targets

| Target | Runs |
| --- | --- |
| `make fix FILES="<files>"` | swiftformat and `swiftlint --fix` (Swift), oxfmt and `oxlint --fix` (TypeScript and JavaScript in `worker/` and `agent/`), `make -C app design` (DESIGN.md) |
| `make lint-ios` | SwiftFormat, SwiftLint with the DESIGN.md token rules, the design-token check, shellcheck, gitleaks |
| `make lint-prkit` | SwiftFormat, SwiftLint with the DESIGN.md token rules, gitleaks |
| `make lint-worker` | oxfmt, oxlint, production and test tsc, shellcheck, gitleaks |
| `make lint-workflows` | actionlint |
| `make build-ios` | The app for the iOS Simulator and the Mac, unsigned |
| `make test-unit-ios` | `swift test --filter PRHubUnitTests` |
| `make test-integration-ios` | `swift test --filter PRHubIntegrationTests` |
| `make test-ui-ios` | The rendering plan, then the UI plan (`SIMULATOR=<udid>` or `SIM_NAME=<name>` picks the Simulator) |
| `make screenshots-ios` | The screenshot plan, into `app/build/screenshots` |
| `make test-unit-prkit` | `swift test --filter PRKitUnitTests` |
| `make test-integration-prkit` | `swift test --filter PRKitIntegrationTests` |
| `make test-unit-worker` | The Worker's and the agent's unit tests |
| `make test-integration-worker` | The Worker's storage, contract and workerd tests, and the agent's integration tests |
| `make lint` | All lint targets |
| `make all-tests` | All test targets |

- The worker targets need `npm ci` in `worker/` and `agent/` first, as in any npm project; the workflows do it in their prepare step.
- The Xcode targets generate `app/PRHub.xcodeproj` (gitignored) from `app/project.yml` and copy `app/Package.resolved`, the app's package pins, into it. Without that file, Xcode writes the app's pins (PostHog too) into the root `Package.resolved`, which belongs to `swift test` on `Package.swift`. Xcode Cloud's `ci_post_clone.sh` does the same copy.

## Hooks

- **Before each commit** (`.pre-commit-config.yaml`, run by prek): `make fix` on the staged files, whose fixes go back into the commit (with the regenerated design tokens when DESIGN.md is staged); then `make lint-<component>` for each component with staged files; and a check that the author is not a work address. prek sets unstaged changes aside while the hooks run, but not untracked files, so a component's lint also reads untracked files in its folders.
- **Before each push**: `make test-unit-<component>` for each component the push changes. The Swift hooks clear git's repo-local variables first (`git rev-parse --local-env-vars`): in a worktree they would send SwiftPM's package checkouts into this repo.
- **Claude Code**: `.claude/hooks/block-no-verify.py` stops a `git commit` or `git push` with `--no-verify`, `-n` or `SKIP=`. `.claude/hooks/fix-edited-file.py` runs `make fix` on each file an agent edits.
- Orca installs the git hooks in each new worktree (`orca.yaml`).

## Disk use

What each workflow leaves on its machine after it ends:

- **Hosted workflows** (all lints but `build-ios`, the worker tests, the release and deploy jobs, the clock workflows): net zero. GitHub discards the VM.
- **`build-ios`, `test-unit-ios`, `test-integration-ios`, `test-unit-prkit`, `test-integration-prkit`**: the checkout, `.build`, the generated project and DerivedData (with its package checkouts) are all in `_work`, which Zoomies deletes with the runner. Not net zero: SwiftPM's download cache (`~/Library/Caches/org.swift.swiftpm`) and mise's installs of the pinned tools (`~/.local/share/mise`). Both are shared by every job on the Mac and grow only when a pinned version changes. Deleting them in a job would slow every later job and race the jobs running beside it.
- **`test-ui-ios`**: as above, plus the job's Simulator. The job deletes the Simulator, the parallel-testing clones a cancelled run leaves in `~/Library/Developer/XCTestDevices`, and the Simulator's logs. The result bundles go to a GitHub artifact for 7 days, not to the Mac. Not net zero: if the runner dies before the cleanup step, its Simulator (named `prhub-ui-<run id>-<attempt>-<job index>`) stays.
- **Mitigation for what stays**: jai/ci's floor on the host already measures free disk, sweeps idle DerivedData and pauses the runners below 150 GB free. If the shared caches or leftover `prhub-ui-*` Simulators ever matter, add them to the floor's idle sweep (jai/ci `hosts/borg-cube-03/host.json`) instead of cleaning in this repo's jobs.

## Deviations from Part 1

Each names what it changes, why, and Jai's approval.

- **`prkit` releases as `v<version>`**, not `prkit-v<version>`. Swift Package Manager reads only `v<version>` tags, and Agent Pager pins PRKit by version. Approval: pending.
- **The RC is the newest commit of `main` that changes the component** or its CI files, not the head of `main`. git-cliff reads a component's commits by path (`--include-path`), and it does not see a release tag on a commit outside those paths. Since `generate-release-candidate` passes `--unreleased`, git-cliff bumps from the newest release tag wherever it is, so this deviation may no longer be needed. Approval: pending.
- **An `ios` release also runs `lint-prkit`, `test-unit-prkit` and `test-integration-prkit`**: the app contains PRKit. Approval: pending.
- **`lint-ios` has a second job, `build-ios`**, and `make build-ios` is a target Part 1 does not list. Part 1 asks for builds of every shipped target on each push, and has no build workflow. Approval: pending.
- **`test-ui-ios` also runs the app-hosted rendering plan.** Its checks are UI-layer: they need the app on a Simulator. Folding it in keeps one make target per workflow, and the release still gates it. Approval: pending.
- **`ios` has fewer integration tests (13) than UI tests (22).** After the test-layer cleanup, the UI tests that remain each need the running app: layout, gestures, system screens and the ways in. Approval: pending.
- **`make screenshots-ios` has no workflow.** It asserts nothing, so it is not a test layer. Approval: pending.
- **`notify-update-available` runs `release/app-latest.test.mjs` before each run.** `release/` belongs to no component, so no test workflow covers it. Approval: pending.
- **`.claude/hooks/fix-edited-file.py`** is a Claude Code hook that Part 1 does not list. Approval: pending.

## Open questions

- **UI timing**: Part 1 leaves it unresolved. `test-ui-ios` runs only in `ios` releases, not on pushes.
- **A screenshots workflow**: should `make screenshots-ios` get one (for example `screenshots-ios`, on the `ios-v` tag), or stay local?
- **`release/app-latest.test.mjs`**: move it into `test-unit-worker`, or give `release/` a test workflow?
- **Runners**: the playbook names Borg Cube 03 and the Mac mini. Since 2026-11-18 the Mac jobs ran on Cube 03, and two `mac` jobs on Cube 04, which the playbook leaves for later. The Mac mini ran none.

## Not in CI

- The self-host kit (`deploy/setup.sh`, `deploy/wrangler.template.jsonc`, `deploy/github-app/`). The code stays.
- Tester Army (`e2e/`). Jai starts it by hand.
