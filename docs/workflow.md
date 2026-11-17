# CI workflow

The CI workflow for PRHub. Part 1 follows the [pinned standard linked from the cleanup prompt](https://github.com/jai/ci/blob/8c65b2fcdda2257c81eb773f42f227c30ae1ebda/docs/workflow.md). Part 2 is custom to PRHub. Swift package tests run natively on macOS, as the cleanup prompt explicitly permits.

# Part 1: Standard for each repo

## Flow

- [ ] Agents push to `main`.
- [ ] After the push, the release workflows make the release with no person.
- [ ] Standard tools and standard make targets do the work.
- [ ] Shell scripts are bash.
- [ ] Each name says what the thing does: each workflow, make target, hook, script and file.

## Components

- [ ] Each component that ships has its own name, workflows, release tag and version.

## Release candidate (RC)

- [ ] An external clock starts `generate-release-candidate` and nothing more. The GitHub schedule is not reliable.
- [ ] Each repo sets its own clock interval.
- [ ] `generate-release-candidate` sets the next version with semantic versioning, from the conventional commits (git-cliff).
- [ ] It tags the head of `main` as `rc-<component>-v<version>-<short hash>`.
- [ ] One RC for each component at a time. The RC workflow cuts nothing while a release run of that component is queued or running.
- [ ] RC tags stay after the release, as the record of what was tested.
- [ ] The RC tag starts `release`.

## Release

- [ ] `release` runs all tests of that component on the RC commit, through `workflow_call`. The tests run in the release run, so its concurrency group holds until the end.
- [ ] If all tests pass, `release` makes the release tag (`<component>-v<version>`) and the GitHub Release, with release notes from git-cliff.
- [ ] If a test fails, `release` stops. The next RC gets the same version.
- [ ] The job that makes the release tag gets its GitHub App token after the tests, because the token stops after 1 hour.

## Test types

- [ ] Unit: the code only. No app, no simulator, no storage, no network.
- [ ] Integration: one component with its own local storage or local services.
- [ ] UI: the app screens on fixed test data.
- [ ] End-to-end: the deployed system.

## Workflows

| Workflow | Runs on |
| --- | --- |
| `lint-<component>` | Push to the component, and RC |
| `test-unit-<component>` | Push to the component, and RC |
| `test-integration-<component>` | Push to the component, and RC |
| `test-ui-<component>` | RC only (from `release`) |
| `deploy-<component>` | Release tag |
| `lint-workflows` | Push that changes `.github/workflows/**` |
| `generate-release-candidate` | The external clock |
| `notify-update-available` | The external clock, each hour |
| `release` | RC tag |

## Other workflow names

These workflows do not follow the `lint-`, `test-` and `deploy-` names in the Workflows table. They are the only exceptions.

| Workflow | What it does | Why the name is different |
| --- | --- | --- |
| `generate-release-candidate` | Tags the RC | It is part of the release flow, not a check of one component |
| `release` | Tests the RC and makes the release tag | It is part of the release flow, not a check of one component |
| `lint-workflows` | Runs actionlint on the workflow files | The workflow files are not a component |
| `notify-update-available` | Each hour, tells the app the newest build that external TestFlight testers can install, for the "Update available" message | It is for the app users, not a check of one component |

## Make targets

| Target | Runs |
| --- | --- |
| `make lint-<component>` | The same check as the `lint-<component>` workflow |
| `make test-<type>-<component>` | The same tests as the `test-<type>-<component>` workflow |
| `make lint` | All lint targets |
| `make all-tests` | All test targets |

## Git and Claude Code hooks

- [ ] Before each commit, a git hook runs `make lint-<component>` for each component that has staged files.
- [ ] Before each push, a git hook runs `make test-unit-<component>` for each component that the push changes.
- [ ] The git hooks are entries in `.pre-commit-config.yaml`.
- [ ] A Claude Code hook, `.claude/hooks/block-no-verify.py`, stops a `git commit` or `git push` that has `--no-verify`.

## iOS apps

- [ ] The app release tag starts Xcode Cloud. Xcode Cloud only builds the archive and sends it to TestFlight external testers.
- [ ] The unit tests run with `swift test` on Swift packages, with no simulator.
- [ ] Xcode test plans are the only source of the UI tests. Each plan has its full test target and names only the skipped tests, so a new test class runs without a change to a file.

## Update available

- [ ] If the app has an "Update available" message, `notify-update-available` runs each hour from the external clock.
- [ ] It asks App Store Connect for the newest build that the external TestFlight group can install. If that build is new, it writes the version and build where the app reads them.
- [ ] Apple does not report when it approves a build, so the workflow asks each hour. A build shows "Update available" within one hour after Apple approves it.

# Part 2: Custom to PRHub

## Runners

- [ ] CI runs on GitHub's own runners: `ubuntu-latest` for Linux, and `xcode-27` for the Mac. They are free for a public repo.
- [ ] No job runs on a self-hosted runner. This repo is public, so outside pull requests would run on Jai's Macs.

## Components

| Component | What it is | Release tag |
| --- | --- | --- |
| `ios` | The iPhone, iPad and Mac app (`app/`). It contains PRKit. | `ios-v<version>` |
| `worker` | The Cloudflare Worker `prhub` (`worker/`, `agent/`, `deploy/hosted/`) | `worker-v<version>` |
| `prkit` | The Swift package that other apps use (`PRKit/`, `Package.swift`) | `v<version>` |

- [ ] `prkit` is the exception to `<component>-v<version>`. Swift Package Manager reads only `v<version>` tags, and Agent Pager pins PRKit by version.
- [ ] `prkit` is the whole package in `Package.swift`: PRKitCore, PRKitDesign, PRKit and FeatureKit. Swift Package Manager gives one version to a package.
- [ ] The app contains PRKit. So a change to PRKit also makes an `ios` RC, and the `ios` release also runs `test-unit-prkit`.
- [ ] `PRHubCore` in `Package.swift` is not a component. It currently compiles the app's logic files (`app/PRHub` without its views) for the Swift package test targets.

## Release candidate

- [ ] This overrides Part 1: `generate-release-candidate` tags the newest commit of `main` that changes the component or its CI files (the Makefile, the workflows, the lint configs), not the head of `main`. git-cliff reads a component's commits by path (`--include-path`), and it does not see a release tag on a commit that changes none of those paths.

## Clock

- [ ] The clock is the release-clock Worker on Cloudflare (jai/ci). It starts `generate-release-candidate` each 3 hours, and `notify-update-available` each hour.

## Test matrix

| Component | Lint | Unit | Integration | UI | Deploy |
| --- | --- | --- | --- | --- | --- |
| `ios` | `lint-ios`: push, RC | `test-unit-ios`: push, RC | `test-integration-ios`: push, RC | `test-ui-ios`: RC | Xcode Cloud: `ios-v` tag |
| `worker` | `lint-worker`: push, RC | `test-unit-worker`: push, RC | `test-integration-worker`: push, RC | | `deploy-worker`: `worker-v` tag |
| `prkit` | `lint-prkit`: push, RC | `test-unit-prkit`: push, RC | `test-integration-prkit`: push, RC | `test-ui-prkit`: RC | None: apps get the `v` tag with Swift Package Manager |

- [ ] Xcode Cloud's "PRHub TestFlight Internal and External" starts on the `ios-v` tag. It builds iOS and macOS and sends them to TestFlight internal and external testers.
- [ ] Deployed-Worker checks live in the separate manual `PRHubE2ETests.xctestplan`; they require an explicitly paired test environment. The release UI plan never includes them. The optional outbox UI check still requires its local stand-in server (`PRHUB_OUTBOX_CHECK`).
- [ ] `test-ui-ios` runs the complete `PRHubUITests.xctestplan` on iPhone and iPad. It includes UI automation and app-hosted rendering checks. Neither runs as a unit test.
- [ ] `test-ui-prkit` selects the complete `PRKitRenderingTests` SwiftPM target on native macOS for AppKit and font checks, without an app host or signing credentials. The iOS rendering target compiles those same sources alongside its UIKit-only checks. It runs on ios and prkit RCs.
- [ ] `test-unit-ios` selects `PRHubUnitTests`; `test-unit-prkit` selects `PRKitUnitTests`. These run code with controlled inputs, without storage, network or an app host.
- [ ] `test-integration-ios` selects `PRHubIntegrationTests`; `test-integration-prkit` selects `PRKitIntegrationTests`. These own local persistence, Keychain and contract-resource checks.
- [ ] The ios release also runs PRKit integration and rendering tests because the app contains PRKit. All test workflows remain inside the RC release run through `workflow_call`.
- [ ] `test-integration-worker` runs Worker local-storage/contract tests, Worker runtime tests in workerd, and the `agent/` tests that start real git and a local server. External services are stubbed in local integration tests.
- [ ] This repo is public. Each `lint-<component>` runs gitleaks on the files of its component.

## Make targets

| Target | Runs |
| --- | --- |
| `make lint-ios` | SwiftFormat, SwiftLint with the DESIGN.md token rules, the design-token check, shellcheck, gitleaks |
| `make lint-prkit` | SwiftFormat, SwiftLint with the DESIGN.md token rules, gitleaks |
| `make lint-worker` | oxlint, oxfmt, production and test tsc, shellcheck, gitleaks |
| `make lint-workflows` | actionlint |
| `make test-unit-ios` | `swift test --filter PRHubUnitTests` |
| `make test-integration-ios` | `swift test --filter PRHubIntegrationTests` |
| `make test-unit-prkit` | `swift test --filter PRKitUnitTests` |
| `make test-integration-prkit` | `swift test --filter PRKitIntegrationTests` |
| `make test-ui-prkit` | `swift test --filter PRKitRenderingTests` on native macOS |
| `make test-ui-ios` | The UI test plan |
| `make test-unit-worker` | The Worker unit tests |
| `make test-integration-worker` | Worker storage/contract tests, workerd tests, and `agent/` tests |
| `make lint` | All lint targets |
| `make all-tests` | All test targets |

## Hooks

- [ ] This adds to Part 1: before the lint, the pre-commit hook runs each tool that can fix a file on the staged files, and adds them back to the commit: swiftformat and `swiftlint --fix` (Swift), oxfmt and `oxlint --fix` (TypeScript and JavaScript), and `make -C app design` when DESIGN.md changes. The commit stops only for what no tool can fix.
- [ ] After each edit, the Claude Code hook `.claude/hooks/format_file.py` formats the file (swiftformat, oxfmt).

## Not in CI

- [ ] The self-host kit (`deploy/setup.sh`, `deploy/wrangler.template.jsonc`, `deploy/github-app/`). The code stays.
- [ ] Tester Army (`e2e/`). Jai starts it by hand.
