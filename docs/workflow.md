# CI workflow

The CI workflow for PRHub. Part 1 is the standard for each of Jai's repos (jai/ci `docs/workflow.md`). Part 2 is custom to PRHub.

# Part 1: Standard for each repo

## Flow

- [ ] Agents push to `main`.
- [ ] After the push, the release workflows make the release with no person.
- [ ] Standard tools and standard make targets do the work.
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
- [ ] The app contains PRKit. So a change to PRKit also makes an `ios` RC, and the `ios` release also runs `test-unit-prkit`.

## Clock

- [ ] The clock is the release-clock Worker on Cloudflare (jai/ci). It starts `generate-release-candidate` each 3 hours, and `notify-update-available` each hour.

## Test matrix

| Component | Lint | Unit | Integration | UI | Deploy |
| --- | --- | --- | --- | --- | --- |
| `ios` | `lint-ios`: push, RC | `test-unit-ios`: push, RC | | `test-ui-ios`: RC | Xcode Cloud: `ios-v` tag |
| `worker` | `lint-worker`: push, RC | `test-unit-worker`: push, RC | `test-integration-worker`: push, RC | | `deploy-worker`: `worker-v` tag |
| `prkit` | `lint-prkit`: push, RC | `test-unit-prkit`: push, RC | | | None: apps get the `v` tag with Swift Package Manager |

- [ ] Xcode Cloud's "PRHub TestFlight External" starts on the `ios-v` tag. It builds iOS and macOS and sends them to TestFlight external testers.
- [ ] `test-ui-ios` runs the UI tests that PRHub has today, on the iPhone and iPad simulators of GitHub's Mac runners.
- [ ] `test-integration-worker` runs the `agent/` tests. They start a real `git` and a local server.
- [ ] This repo is public. Each `lint-<component>` runs gitleaks on the files of its component.

## Make targets

| Target | Runs |
| --- | --- |
| `make lint-ios` | SwiftFormat, SwiftLint with the DESIGN.md token rules, the design-token check, gitleaks |
| `make lint-prkit` | SwiftFormat, SwiftLint with the DESIGN.md token rules, gitleaks |
| `make lint-worker` | oxlint, oxfmt, tsc, gitleaks |
| `make lint-workflows` | actionlint |
| `make test-unit-ios` | `swift test` on the app packages |
| `make test-unit-prkit` | `swift test` on PRKit |
| `make test-ui-ios` | The UI test plan |
| `make test-unit-worker` | The Worker unit tests |
| `make test-integration-worker` | The `agent/` tests |
| `make lint` | All lint targets |
| `make all-tests` | All test targets |

## Not in CI

- [ ] The self-host kit (`deploy/setup.sh`, `deploy/wrangler.template.jsonc`, `deploy/github-app/`). The code stays.
- [ ] Tester Army (`e2e/`). Jai starts it by hand.
