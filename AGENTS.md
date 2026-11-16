# AGENTS.md

This repo is the source of PRHub: an iPhone app for reviewing GitHub pull requests, PRKit (the Swift package with its
PR screens), the Cloudflare Worker that each person deploys to their own account, and the push relay.

**CI rules:** before you add or change a workflow, or build, test, run a simulator or drive a desktop on one of
Jai's Macs, read [RULES.md in jai/ci](https://github.com/jai/ci/blob/main/RULES.md).

<!-- BEGIN jai/ci standard section -->
## Shipping (standard for all of Jai's projects)

- **Push to main.** Work on `main` in your own clone or worktree. No feature branches and
  no pull requests. The only pull requests are the ones bots open (release-please);
  they merge themselves once green. Dependabot is off (Jai, 2026-11-15).
- **Land a change:** commit small (Conventional Commits, signed), `git pull --rebase origin
  main`, run this repo's fast checks, push. A push rejected because main moved means
  someone landed first: rebase, run the checks again, push again. Never force-push.
- **Main stays green.** Watch the run for your commit (`gh run watch`). If your push turns
  main red, fixing it is your next task: fix forward, or `git revert` your commit, within
  the hour.
- **Deploy through CI.** For conformance and correctness, production deploys run in the
  repo's deploy workflow. A manual deploy is fine in an exceptional case or when the user
  asks for one.
- **Releases are not yours to cut.** An hourly job tests main's newest commit and releases
  it if it passes. Do not tag or bump versions by hand.
- **Unfinished work** goes behind a feature flag, not on a branch.
- **Parallel agents:** one worktree each, small changes, rebase often.
- **Where CI runs and what you may run on Jai's Macs:**
  [RULES.md in jai/ci](https://github.com/jai/ci/blob/main/RULES.md).
<!-- END jai/ci standard section -->

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
  XcodeGen), `worker/` (the Worker), `relay/` (the push relay), `deploy/` (template, `setup.sh`, deployment guide,
  `github-app/`), `docs/` (contracts, `fixtures/`, plans), `release/` (TestFlight), `scripts/` (repo checks),
  `e2e/` (agentic bug bashes and repro tests on the Simulator, [e2e/README.md](e2e/README.md)).
- Contracts: [docs/api.md](docs/api.md) (pairing, `/device/config`, every var and secret) and
  [docs/push-relay.md](docs/push-relay.md). Whoever changes API behaviour updates the contract in the same commit.
- **Push to `main`, then deploy. No pull requests.** GitHub enforces it: no new branches (except `ci/…` and
  release-please's), and `main` takes only signed, linear pushes, never a force push; `v*` tags never move. Commit (signed) on `main`, `git pull --rebase`, run the local
  checks below for what you touched, push, and deploy what changed in the same session:
  - `worker/` or `agent/`: the hosted Worker ([docs/hosted-deploy.md](docs/hosted-deploy.md)).
  - `PRKit/`: a new `v*` tag; `app/`: a PRHub release ("Releases" below).
  Jai's Agent Pager follows on its own: within 10 minutes it moves to `main`'s head and to the newest `v*` tag, tests,
  and deploys. Nothing to commit there, and never deploy its Worker by hand.
  Merging is not releasing. Every push to `main` runs only the fast checks on GitHub's own runners: `scrub`, `worker`,
  `relay`, and, when PRKit, the app or DESIGN.md change, `design` and `build` on a Mac (`.github/workflows/ios.yml`,
  the `xcode-27` image: the app and its tests build once, and PRKit's `swift test` runs). No Xcode Cloud workflow
  starts on a push or a pull request. Once an hour, when `main` changed the app, the hourly release ("Releases" below)
  runs the full tests on `main`'s head, then releases it if they pass: five `test (…)` jobs run the unit and UI
  tests from `build`, two slices on the iPhone 17 and three on the 13-inch iPad Pro
  (`scripts/ui-test-slices.py`, by each test's seconds in `app/PRHubUITests/times.txt`; a new test needs no entry).
  A slice is no shorter than its longest test, so keep a long walk as several tests. A red hourly run is fixed next,
  by whoever pushed the commits it tested (GitHub → Actions → hourly-release). Each test job keeps
  its result bundle a week: `gh run download <run> -n 'xcresult-iPhone 17-1'` (device, then slice), then
  `xcrun xcresulttool export attachments`. Every test by hand: `gh workflow run ios.yml`. One test by hand: `gh workflow run ios.yml -f only=PRHubUITests/<Class>/<test>`.
  A UI test's `waitForExistence` looks at once and every 0.1 s (`app/PRHubUITests/FastWaits.swift`), so use it freely.
  Xcode Cloud makes the builds only, from the `v*` tag each release makes.
- Tests: `npm test` and `npm run typecheck` in `worker/` and `relay/`. The worker's contract test compares what the
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
  type a font size, colour, padding, corner or animation in a view: `scripts/design-lint.sh` fails CI on one. Token
  changes go in DESIGN.md, then `make -C app design`.
- App build options live in `app/Config/PRHub.xcconfig` and reach the app through Info.plist (`PRHubBuild`):
  `PRHUB_HOSTED_HOST` (the hosted Worker: Sign in with GitHub, its HTTPS callback and the `webcredentials`
  associated domain; a custom domain is this one line), and onboarding's ways in, `YES` or `NO`:
  `PRHUB_SIGN_IN_GITHUB` (default `YES`), `PRHUB_SELF_HOSTED` (default `NO`: no "Connect your own Worker", and a
  `prhub://setup` link says self-hosted Workers aren't enabled; a Worker paired before keeps working) and
  `PRHUB_SAMPLES` (default `YES`; App Review needs it). A Debug build takes each as a launch argument for the UI tests
  (`-PRHubSelfHosted YES`); `-PRHubFirstRun` and `-PRHubHosted` run against a fake hosted Worker
  (`app/PRHub/Debug/PRHubScreenshots.swift`).
- Public repo: run `scripts/scrub.sh` before every push. It fails on a private name, id, host or token. Test data
  uses made-up names (`acme`, `octocat`).
- Jai's own deployments (his Worker and the relay) build from a pinned ref of this repo with private config kept
  elsewhere. Nothing here may depend on that config.
- Commits: conventional (`feat(worker): …`, `fix(relay): …`, `feat(prkit): …`, `fix(app): …`, `docs: …`), signed.

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

- **Releases are automatic.** Never tag `v*`, edit `MARKETING_VERSION` or edit `CURRENT_PROJECT_VERSION` by hand.
- **The hourly release** (`.github/workflows/hourly-release.yml`) runs when jai/ci's release-clock Worker starts it,
  at the top of each hour. `release/version.mjs plan` reads the conventional commits since the newest `vX.Y.Z` tag on
  `main`. Below 1.0.0, a `feat` or breaking change bumps the minor and a `fix` or `perf` the patch; other types make no
  release. When a release is due, `ios.yml` runs the full tests on main's head. When they pass,
  `release/version.mjs publish` tags the commit (annotated; the message lists the feat and fix subjects) and makes a
  GitHub Release with the same notes. Red tests release nothing. `gh workflow run hourly-release.yml -f retry=true`
  runs it now and tries a red commit again.
- **The tag starts the build.** Xcode Cloud's workflow starts on a `v*` tag, never on a push, and hands the build to
  TestFlight. `app/ci_scripts/ci_post_clone.sh` sets `MARKETING_VERSION` to the newest tag reachable from the commit
  and `CURRENT_PROJECT_VERSION` to Xcode Cloud's build number. `app/ci_scripts/ci_post_xcodebuild.sh` writes the tag's
  notes as What to Test. Xcode Cloud's **Next Build Number** (App Store Connect → PRHub → Xcode Cloud → Settings) must
  stay above TestFlight's highest build, or the upload is refused.
- **PRKit's versions are the same tags.** Apps pin PRKit (`from: "0.1.0"`); Jai's Agent Pager is one of them.
- **Update available.** `release/app-latest.mjs`, in the same hourly run, writes the newest build each TestFlight group
  can install to `app-latest.json` on the branch `ci/app-latest`, which the Workers' `GET /device/config` reads.
- Xcode Cloud resolves packages only from a `Package.resolved`. `app/Package.resolved` pins the remote ones (PostHog)
  and `app/ci_scripts/ci_post_clone.sh` copies it into the generated project. When `project.yml`'s packages change,
  run `xcodebuild -resolvePackageDependencies` in `app/` and copy the project's `Package.resolved` back to `app/`.
- The Mac app's icon sizes come from `swift app/Tools/icon/mac-icon.swift`; run it when `PRHubIcon.png` changes.
