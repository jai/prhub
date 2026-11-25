# CI workflow

PRHub's CI follows Jai's personal CI standard ([personal-ci-standard.md](https://github.com/jai/skills/blob/9bb45df/jstack/skills/personal-projects/references/personal-ci-standard.md), Part 1). This file is the standard's Part 2 for this repo: what PRHub runs, where, and each deviation from Part 1 with its reason.

## Runners

- **GitHub-hosted Ubuntu** runs everything that needs no Mac: `lint-ios` and `lint-prkit` (on `ubuntu-24.04`: SwiftLint's Linux build needs libxml2.so.2), `lint-worker`, `lint-workflows`, `test-unit-worker`, `test-integration-worker`, `generate-release-candidate`, the `release` job of `release`, `deploy-worker` and `notify-update-available`. GitHub discards each VM after its job.
- **GitHub-hosted Macs** (`runs-on: xcode-27`) run the Mac work: `build-ios`, the `swift test` workflows, `test-ui-ios`, `test-ui-prkit` and `test-ui-mac`. GitHub discards each VM after its job (see "Disk use").
- Only pushes to `main`, RC tags, the clock and a dispatch of `test-ui-mac` start workflows. No workflow runs on a pull request, so no fork's code reaches the home lab.
- **This repo is public, so every job runs on GitHub's runners, never on Jai's Macs** (Jai, 2026-11-25). That includes the Mac UI tests, which control the screen of the Mac they run on.

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
Manual library validation selects `component=prkit` on `generate-release-candidate`; the clock retains the default
`all`. The other matrix entries skip candidate creation when one component is selected.

## How a workflow reads

Each lint and test workflow has the same three parts, in this order:

1. **Prepare**: the checkout, the tools (Node, or mise for the pinned tools), the npm dependencies, and for each UI workflow a Simulator of the job's own.
2. **Test** (or lint, or build): one make target, the workflow's own name. The make target is what a person runs locally.
3. **Clean up**: only what lives outside the runner's work folder. The work folder itself goes with the runner (see "Disk use").

Each test workflow runs one test layer of one component. Each push workflow runs on the paths of its component, the Makefile and its own file; lint workflows also run when their lint configuration changes.

## Test matrix

| Component | Lint | Unit | Integration | UI | Deploy |
| --- | --- | --- | --- | --- | --- |
| `ios` | `lint-ios` (with `build-ios`): push, RC | `test-unit-ios`: push, RC | `test-integration-ios`: push, RC | `test-ui-ios`, `test-ui-mac`: RC | Xcode Cloud: `ios-v` tag |
| `worker` | `lint-worker`: push, RC | `test-unit-worker`: push, RC | `test-integration-worker`: push, RC | | `deploy-worker`: `worker-v` tag |
| `prkit` | `lint-prkit`: push, ios and prkit RC | `test-unit-prkit`: push, ios and prkit RC | `test-integration-prkit`: push, ios and prkit RC | `test-ui-prkit`: ios and prkit RC | None: apps get the `v` tag with Swift Package Manager |

- **Unit**: `swift test` on `PRHubUnitTests` and `PRKitUnitTests`; Vitest project `unit` in `worker/` and `agent/`. No app host, storage or network.
- **Integration**: `swift test` on `PRHubIntegrationTests` (persistence, Keychain, contract fixtures) and `PRKitIntegrationTests` (persistence, contract fixtures, bundled fonts, and the AppKit checks of `PRKit/Tests/PRKitRenderingTests`); Vitest projects `integration-node` and `integration-runtime` (workerd) in `worker/`, and `integration` in `agent/` (a real git and a local server). Outside services are stubbed.
- **UI**: `make test-ui-prkit` runs `PRKitRenderingTests` (library rendering) then `PRKitUITests` (native gestures, navigation and the review keyboard). Sources live under `PRKit/Tests`; the controlled PRHub app is their test host. Rendering constructs direct library models with canonical in-memory storage support, while interaction tests share only PRHub's launch/navigation support and sample host. `make test-ui-ios` runs `PRHubRenderingTests` (app build settings and account-sheet width) then `PRHubUITests` (Settings, onboarding, account, sample and link wiring). Each rendering plan runs serially without retries; each interaction plan runs serially on the same owned Simulator and retries a failing test once. Both workflows run on iPhone 17 and iPad Pro 13-inch Simulators. Each plan selects its complete named target; there is no selected-test allowlist. The app UI target does not include library assertion sources.
- **Mac UI**: `make test-ui-mac` runs `PRHubMacUITests`, what only the Mac app's own windows show and no Simulator does: the PRs window's toolbar and the Feedback window it opens, a PR card lifting under the pointer, and a PR link from another app opening in the window that is open. It runs on a hosted Mac's desktop, serially, with the app signed to run on that Mac only, retries a failing test once, and stops and fails a test that hangs after 2 minutes. These tests control the screen, so nobody runs them by hand on Jai's Macs (`AGENTS.md`, "Tests on Jai's Macs"). To run them on a branch: `gh workflow run test-ui-mac.yml -R jai/prhub --ref <branch>`.
- **End-to-end**: `PRHubE2ETests.xctestplan` and `PRHubE2EPairingTests.xctestplan` need a paired deployed Worker; a person runs them. Tester Army (`e2e/`) is started by hand.
- **Not in CI**: `PRHubPerformanceTests.xctestplan` needs a physical device.
- `deploy-worker` deploys with `wrangler deploy` (`deploy/hosted/wrangler.jsonc`) and then checks that the live Worker answers. Xcode Cloud's "PRHub TestFlight Internal and External" starts on the `ios-v` tag and only archives and uploads; `app/ci_scripts/ci_post_clone.sh` generates the project for it.
- This repo is public. Each `lint-<component>` runs gitleaks on its component's files.

## Release order

`generate-release-candidate` tags the current head of `main`. Component paths determine the next version, while the tested source tree includes every current test-host fix. Git-cliff uses `--unreleased` to bump from the newest component release tag even when that tag points to a commit outside the component paths.

`release` runs the checks of the RC's component in its own run, cheapest first. Lint and unit tests start together; integration waits for its unit tests. `test-ui-prkit` waits for the kit's cheap checks and, on an ios RC, every cheap app check too. Its explicit condition allows app-only checks to be skipped on a prkit RC. `test-ui-ios` then waits for the kit UI gate and the app's cheap checks, without rerunning library UI; `test-ui-mac` waits for the same checks and runs beside it. The UI gates run inside the same release run and hold that component's concurrency group. Worker RCs skip both. The final `release` job requires every check that ran to pass, including the kit UI gate and the Mac UI gate.

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
| `make test-ui-mac` | The Mac UI plan, on the desktop of the Mac it runs on. CI's; not in `make all-tests` |
| `make test-unit-prkit` | `swift test --filter PRKitUnitTests` |
| `make test-integration-prkit` | `swift test --filter PRKitIntegrationTests` |
| `make test-ui-prkit` | PRKit rendering, then native library interactions, using the same Simulator selection |
| `make test-unit-worker` | The Worker's and the agent's unit tests |
| `make test-integration-worker` | The Worker's storage, contract and workerd tests, and the agent's integration tests |
| `make lint` | All lint targets |
| `make all-tests` | All test targets except `test-ui-mac` |

- The Swift test targets use four build jobs by default; `SWIFT_JOBS=2` limits local validation when sharing a Mac.
- The worker targets need `npm ci` in `worker/` and `agent/` first, as in any npm project; the workflows do it in their prepare step.
- The Xcode targets generate `app/PRHub.xcodeproj` (gitignored) from `app/project.yml` and copy `app/Package.resolved`, the app's package pins, into it. Without that file, Xcode writes the app's pins (PostHog too) into the root `Package.resolved`, which belongs to `swift test` on `Package.swift`. Xcode Cloud's `ci_post_clone.sh` does the same copy.

## Hooks

- **Before each commit** (`.pre-commit-config.yaml`, run by prek): `make fix` on the staged files, whose fixes go back into the commit (with the regenerated design tokens when DESIGN.md is staged); then `make lint-<component>` for each component with staged files; and a check that the author is not a work address. prek sets unstaged changes aside while the hooks run, but not untracked files, so a component's lint also reads untracked files in its folders.
- **Before each push**: `make test-unit-<component>` for each component the push changes. The Swift hooks clear git's repo-local variables first (`git rev-parse --local-env-vars`): in a worktree they would send SwiftPM's package checkouts into this repo.
- **Claude Code**: `.claude/hooks/block-no-verify.py` stops a `git commit` or `git push` with `--no-verify`, `-n` or `SKIP=`. `.claude/hooks/fix-edited-file.py` runs `make fix` on each file an agent edits.
- Orca installs the git hooks in each new worktree (`orca.yaml`).

## Superseded main checks

Main app and kit checks share a per-workflow, per-ref concurrency group. A newer main push cancels that workflow's
older pending/running main check, keeping the hosted Mac slots from replaying obsolete commits. Reusable checks on
RC tags have separate groups and never cancel in progress; release serialization still holds through all gates.

## Disk use

All jobs use GitHub-hosted runners: native Swift and UI checks use `macos-26`, and Linux checks and release metadata use hosted Ubuntu. GitHub discards each job's VM, including the checkout, build products, tool/download caches and any simulator left by an interrupted cleanup.

Native Xcode builds default to two compiler jobs (`JOBS=2`). The hosted arm64 Mac has [3 cores and 7 GB RAM](https://docs.github.com/en/actions/reference/runners/github-hosted-runners); UI jobs use one owned simulator, with parallel testing disabled for both rendering and interactions. This avoids the extra booted clone that timed out initializing Accessibility during the first hosted PRKit iPad run. UI jobs delete their own simulator in their cleanup step; `test-ui-mac` uses none and has no cleanup step. On failure, original result bundles and diagnostics go to a GitHub artifact for three days; successful jobs upload no test evidence.

## Deviations from Part 1

Each names what it changes, why, and Jai's approval.

- **`prkit` releases as `v<version>`**, not `prkit-v<version>`. Swift Package Manager reads only `v<version>` tags, and Agent Pager pins PRKit by version. Approval: pending.
- **An `ios` release also runs `lint-prkit`, `test-unit-prkit`, `test-integration-prkit` and `test-ui-prkit`**: the app contains PRKit. Approval: pending.
- **`lint-ios` has a second job, `build-ios`**, and `make build-ios` is a target Part 1 does not list. Part 1 asks for builds of every shipped target on each push, and has no build workflow. Approval: pending.
- **`test-ui-ios` and `test-ui-prkit` also run their app-hosted rendering plans.** Its checks are UI-layer: they need the app on a Simulator. Folding it in keeps one make target per workflow, and the release still gates it. Approval: pending.
- **`notify-update-available` runs `release/app-latest.test.mjs` before each run.** `release/` belongs to no component, so no test workflow covers it. Approval: pending.
- **`.claude/hooks/fix-edited-file.py`** is a Claude Code hook that Part 1 does not list. Approval: pending.

## Open questions

- **`release/app-latest.test.mjs`**: move it into `test-unit-worker`, or give `release/` a test workflow?
- **Runners**: the playbook names Borg Cube 03 and the Mac mini. Since 2026-11-18 the Mac jobs ran on Cube 03, and two `mac` jobs on Cube 04, which the playbook leaves for later. The Mac mini ran none.

## Not in CI

- The self-host kit (`deploy/setup.sh`, `deploy/wrangler.template.jsonc`, `deploy/github-app/`). The code stays.
- Tester Army (`e2e/`). Jai starts it by hand.
