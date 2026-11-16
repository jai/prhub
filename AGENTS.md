# AGENTS.md

This repo is the source of PRHub: an iPhone app for reviewing GitHub pull requests, PRKit (the Swift package with its
PR screens), and the Cloudflare Worker (hosted as `prhub`; self-hosting is on its way out).

**CI rules:** before you add or change a workflow, or build, test, run a simulator or drive a desktop on one of
Jai's Macs, read [RULES.md in jai/ci](https://github.com/jai/ci/blob/main/RULES.md).

<!-- BEGIN jai/ci standard section -->
## CI, releases and deploys

This repo follows [RULES.md in jai/ci](https://github.com/jai/ci/blob/main/RULES.md), the
one place for these rules: push to main (no branches or pull requests), main stays green,
release-please releases hourly, the release tag deploys, and what you may run on Jai's
Macs. Read it before you change a workflow, release, deploy or run work on a Mac.
<!-- END jai/ci standard section -->

**Checks:** run `make setup` once per clone, and `make check` before you push.

## If you were asked to deploy PRHub

Follow [deploy/AGENTS.md](deploy/AGENTS.md). It is the whole deployment guide: prerequisites, each step with a check,
pairing the phone, and troubleshooting.

- Never print, log or commit a secret. Pass each secret in the environment of one command, as the guide does.
- Ask your human for the Cloudflare API token, the GitHub token and any optional key. Do not make or reuse one
  yourself.
- Run each step's check before the next step. Stop at the first check that fails and use the guide's
  Troubleshooting table.

## Feedback requests

Jai's feedback for PRHub arrives two ways: from the app's Feedback screen (each message starts an agent chat in its
own worktree of a feedback clone), and as GitHub issues labelled `feedback`. A long-running feedback manager agent
works new `feedback` issues, checks that each feedback chat's work landed on `main`, and flags anything stuck.

## If you are changing the code

- Layout: `PRKit/` with the root `Package.swift` (the PR screens as a Swift package), `app/` (the PRHub app,
  XcodeGen), `worker/` (the Worker), `deploy/` (template, `setup.sh`, deployment guide,
  `github-app/`), `docs/` (contracts, `fixtures/`, plans), `scripts/` (`ask-trace.sh`),
  `e2e/` (agentic bug bashes and repro tests on the Simulator, [e2e/README.md](e2e/README.md)).
- Contracts: [docs/api.md](docs/api.md) (pairing, `/device/config`, every var and secret) and
  the hosted deploy, [docs/hosted-deploy.md](docs/hosted-deploy.md). Whoever changes API behaviour updates the contract in the same commit.
- **Push to `main`, then deploy. No pull requests.** GitHub enforces it: no new branches (except `ci/…`), and `main` takes only signed, linear pushes, never a force push; `v*` tags never move. Commit (signed) on `main`, `git pull --rebase`, run the local
  checks below for what you touched, and push. Never deploy by hand: each `vX.Y.Z` release ("Releases" below)
  deploys the hosted Worker (`.github/workflows/deploy-worker.yml`) and starts the app's TestFlight build, and PRKit's
  users pin the same tags. A deploy by hand is for an emergency Jai asks for ([docs/hosted-deploy.md](docs/hosted-deploy.md)).
  Jai's Agent Pager follows on its own: within 10 minutes it moves to `main`'s head and to the newest `v*` tag, tests,
  and deploys. Nothing to commit there, and never deploy its Worker by hand.
  Merging is not releasing. Every push to `main` runs the fast checks, `ci` (`.github/workflows/ci.yml`), on GitHub's
  own runners (the `xcode-27` image): **Lint** (`make lint typecheck`), **Unit Tests** (`make test`) and **Unit Tests
  (app)** (`make test-app`, the app's unit tests on an iPhone Simulator). A red `ci` on `main` is fixed next, by
  whoever pushed. The slow **UI Tests** (`test-ui.yml`, `make test-ui` on the iPhone 17 and the 13-inch iPad Pro) run
  only for a release ("Releases" below), or by hand: `gh workflow run test-ui.yml`. Each UI test job keeps its test
  logs a week as an artifact.
  A UI test's `waitForExistence` looks at once and every 0.1 s (`app/PRHubUITests/FastWaits.swift`), so use it freely.
  Xcode Cloud makes the builds only, from the `v*` tag each release makes.
- Tests: `npm test` and `npm run typecheck` in `worker/`. The worker's contract test compares what the
  real builders send with `docs/fixtures/*.json`; after a deliberate change run `UPDATE_FIXTURES=1 npm test` and
  commit the fixtures with the code.
- iOS: Swift 6, iOS 26, SwiftUI, Xcode 26. `swift test` for PRKit; `make -C app test` and `make -C app ui-test` for
  the app on a Simulator, on the sample PRs (`-PRHubFirstRun`, `-PRHubPaired`), with no Worker. Every UI test passes on
  an iPhone and on an iPad (`make -C app ui-test SIM_NAME='iPad Pro 13-inch (M5)'`; CI runs both): reach a tab with `app.go(to:)` in `UITestSupport.swift`, by accessibility identifier, never
  through `tabBars`. Xcode Cloud's test Macs have no sources: a test that reads a repo file runs only where the
  repo is (`RepoFixtures.areHere`), or bundles the file.
  PRKit is public API for other apps: a change to `PRKitHost`, `PRKitController` or `PRKitConfiguration` is a
  breaking change for them, so it needs a new minor version tag.
- Design: [DESIGN.md](DESIGN.md) is the one design reference for PRKit and PRHub (Agent Pager follows it for PRKit's
  screens). Build new UI from its tokens and shared parts; its "Making a change" table says which line to edit. Never
  type a font size, colour, padding, corner or animation in a view: SwiftLint's `design_*` rules (`.swiftlint.yml`)
  fail `make lint` on one; a real exception is `// swiftlint:disable:next design_<rule> - <why>`. Token
  changes go in DESIGN.md, then `make -C app design`.
- App build options live in `app/Config/PRHub.xcconfig` and reach the app through Info.plist (`PRHubBuild`):
  `PRHUB_HOSTED_HOST` (the hosted Worker: Sign in with GitHub, its HTTPS callback and the `webcredentials`
  associated domain; a custom domain is this one line), and onboarding's ways in, `YES` or `NO`:
  `PRHUB_SIGN_IN_GITHUB` (default `YES`), `PRHUB_SELF_HOSTED` (default `NO`: no "Connect your own Worker", and a
  `prhub://setup` link says self-hosted Workers aren't enabled; a Worker paired before keeps working) and
  `PRHUB_SAMPLES` (default `YES`; App Review needs it). A Debug build takes each as a launch argument for the UI tests
  (`-PRHubSelfHosted YES`); `-PRHubFirstRun` and `-PRHubHosted` run against a fake hosted Worker
  (`app/PRHub/Debug/PRHubScreenshots.swift`).
- Public repo: `make lint` runs gitleaks (`.gitleaks.toml`), which fails on a secret or a private name, id or host,
  in the pre-commit hook and in CI. Test data
  uses made-up names (`acme`, `octocat`).
- Jai's own deployments build from a pinned ref of this repo with private config kept
  elsewhere. Nothing here may depend on that config.
- Commits: conventional (`feat(worker): …`, `feat(prkit): …`, `fix(app): …`, `docs: …`), signed.

## Analytics

The app sends anonymous usage events to PostHog. PRIVACY.md and docs/privacy/hosted.md promise what they carry, so a
new event that breaks a rule below is a privacy policy change, not a code change.

- **Add an event.** Add a case to `AnalyticsEvent` (`app/PRHub/Analytics/AnalyticsEvent.swift`), with its name, one
  snake_case literal, and its properties. Record it with `usage.record(.yourEvent)` where the action finishes. Add the
  case to `AnalyticsTests.everyEvent` and `kind`; the tests then check its payload. PRKit's events arrive through
  `PRKitHost.receive` and map in `AnalyticsEvent.init?(_: PRKitEvent)`.
- **What a property can be.** A case of a closed enum (`CaseIterable`, with `String` raw values), an `Int` or a
  `Bool`. Never a `String`, a `URL`, a `PullRequestRef` or a dictionary: `AnalyticsTests` fails on one.
- **Banned in any event:** GitHub logins, user IDs and emails, repo, org and branch names, PR numbers and titles, file
  paths, code, comments, error messages, Worker hosts, push tokens and anything typed. Send an error as its code.
- **Screens.** `AnalyticsScreen` names them, generically. PostHog's automatic screen views, taps, session replay,
  push-token capture and crash reports stay off (`PostHogAnalytics`).
- **Vendor.** Only `PostHogAnalytics.swift` imports PostHog. Another vendor is another `Analytics` conformance.
- **Config.** `PRHUB_ANALYTICS_KEY` and `PRHUB_ANALYTICS_HOST` in `app/Config/PRHub.xcconfig`. An empty key sends
  nothing, and so do Debug builds and tests. Settings' **Share anonymous usage** turns it off.
- **App Store.** A new kind of data changes the answers in [docs/app-store-privacy.md](docs/app-store-privacy.md) and
  `app/PRHub/PrivacyInfo.xcprivacy`.

## Releases

- **Releases are automatic.** Never tag `rc-*` or `v*`, edit `MARKETING_VERSION` or edit `CURRENT_PROJECT_VERSION` by
  hand. A release is one commit: tagged as a release candidate, tested, then released.
- **Generate release candidate** (`.github/workflows/generate-release-candidate.yml`): jai/ci's release-clock starts it
  every 3 hours when `main` has a `feat`, `fix`, `perf` or breaking commit since the newest `vX.Y.Z`. git-cliff
  (`cliff.toml`) gives the next version (feat: minor, fix or perf: patch, breaking: major; other types release
  nothing) and it tags `main`'s head `rc-vX.Y.Z`. One candidate at a time: while an `rc-*` tag exists, it cuts nothing.
  By hand: `gh workflow run generate-release-candidate.yml`.
- **Release** (`.github/workflows/release.yml`), on the `rc-*` tag: `ci` and `test-ui` on that commit. Green: the
  commit gets `vX.Y.Z` and a GitHub Release, both with git-cliff's notes. Green or red, the `rc-*` tag is then deleted.
  A red candidate is not fixed: fix forward on `main`, and the next candidate takes it.
- **The tag starts the build.** Xcode Cloud's "PRHub TestFlight External" starts on a `v*` tag, never on a push, and
  ships iOS and macOS to the external group. `app/ci_scripts/ci_post_clone.sh` generates the project, sets
  `MARKETING_VERSION` from the tag (`CI_TAG`) and `CURRENT_PROJECT_VERSION` to Xcode Cloud's build number. Xcode
  Cloud's **Next Build Number** (App Store Connect → PRHub → Xcode Cloud → Settings) must stay above TestFlight's
  highest build, or the upload is refused. The GitHub Release deploys the hosted Worker (`deploy-worker.yml`).
- **PRKit's versions are the same tags.** Apps pin PRKit (`from: "0.1.0"`); Jai's Agent Pager is one of them.
- Xcode Cloud resolves packages only from a `Package.resolved`. `app/Package.resolved` pins the remote ones (PostHog)
  and `app/ci_scripts/ci_post_clone.sh` copies it into the generated project. When `project.yml`'s packages change,
  run `xcodebuild -resolvePackageDependencies` in `app/` and copy the project's `Package.resolved` back to `app/`.
- The Mac app's icon sizes come from `swift app/Tools/icon/mac-icon.swift`; run it when `PRHubIcon.png` changes.
