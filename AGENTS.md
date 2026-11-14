# AGENTS.md

This repo is the source of PRHub: an iPhone app for reviewing GitHub pull requests, PRKit (the Swift package with its
PR screens), the Cloudflare Worker that each person deploys to their own account, and the push relay.

**CI rules:** before you add or change a workflow, or build, test, run a simulator or drive a desktop on one of
Jai's Macs, read [RULES.md in jai/ci](https://github.com/jai/ci/blob/main/RULES.md).

## If you were asked to deploy PRHub

Follow [deploy/AGENTS.md](deploy/AGENTS.md). It is the whole deployment guide: prerequisites, each step with a check,
pairing the phone, and troubleshooting.

- Never print, log or commit a secret. Pass each secret in the environment of one command, as the guide does.
- Ask your human for the Cloudflare API token, the GitHub token and any optional key. Do not make or reuse one
  yourself.
- Run each step's check before the next step. Stop at the first check that fails and use the guide's
  Troubleshooting table.

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
  Xcode Cloud makes the builds only, when the hourly release starts them. It has three workflows: Internal -
  TestFlight, Internal - TestFlight (Mac) and PRHub Release.
  The scripts in `app/ci_scripts` know each workflow by its id (`workflows.sh`), never its name.
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

- **Versions are automatic.** Never tag `v*` or edit `MARKETING_VERSION` by hand. Before each Internal build,
  `release/cadence.mjs` (`release/version.mjs`) reads the conventional commits since the newest `vX.Y.Z` tag on
  `main`: below 1.0.0, a `feat` or breaking change bumps the minor, a `fix` or `perf` the patch; only other types keep
  the version and make no tag. It tags the released commit (annotated; the message lists the feat/fix subjects) and
  makes a GitHub Release with the same notes, only after the commit's tests passed. Xcode Cloud (`app/ci_scripts/ci_post_clone.sh`) builds every workflow as the
  newest tag reachable from its commit. PRKit's tags are the same tags: apps pin it (`from: "0.1.0"`); Jai's Agent
  Pager is one of them.
- **The hourly release** (`.github/workflows/hourly-release.yml`, at minute 7) is the only thing that starts an Xcode
  Cloud workflow. `release/cadence.mjs decide` picks `main`'s head only when `app/`, `PRKit/`, `Package.swift` or
  `DESIGN.md` changed since the last Internal build, and never while a build of it is running or when a scheduled run
  already failed on that commit. `ios.yml` runs the full tests on it. When they pass, `release/cadence.mjs release`
  points the branch `ci/release` at the commit, makes its version, and starts Xcode Cloud's **Internal -
  TestFlight** (and the Mac's, and **PRHub Release** when a release commit waits) on `ci/release`, so Xcode Cloud
  builds the commit that was tested. Red tests release nothing. `gh workflow run hourly-release.yml` runs it now, and
  tries a red commit again.
- **PRHub for the Internal group**: the hourly release's Internal - TestFlight build. The build goes to the Internal TestFlight group with its version's notes as What to Test (the commit's subject when
  it made no new version). Xcode Cloud numbers the build itself; its **Next Build Number** (App Store Connect → PRHub
  → Xcode Cloud → Settings) must stay above TestFlight's highest build, or the upload is refused. Nothing to run; `node release/cadence.mjs decide --dry-run`
  says what it would do.
  The Mac app goes to the same group from a workflow of its own, **Internal - TestFlight (Mac)**, which the hourly release
  starts with the phone's build on the same commit. Its build has its own number, and `release/app-latest.mjs` counts
  only the phone's builds. The Internal group's "all builds" does not take a Mac build: the Mac workflow's TestFlight
  post-action (Internal group, set in App Store Connect; the API cannot) does. Without it, Macs install the iPad build. The
  Mac's icon sizes come from `swift app/Tools/icon/mac-icon.swift`; run it when `PRHubIcon.png` changes. The Public
  group has no Mac build yet.
- **PRHub for the Public group**: a release is one commit on `main` that sets `CURRENT_PROJECT_VERSION` in `app/project.yml` to N, with
  the subject `chore(release): PRHub build N — <What to Test>`. Take N from `release/next-build.sh`, change nothing
  else in that commit, and change `CURRENT_PROJECT_VERSION` in no other commit.
  1. Push the release commit to `main`. The next hourly release starts Xcode Cloud's **PRHub Release** workflow once
     the tests pass, when the newest change to `app/project.yml` is a release that no run of it has built.
     `app/ci_scripts` checks that the change is a release, sets the build number to
     Xcode Cloud's (TestFlight shows that number), generates the project, archives and writes What to Test from the
     subject. The workflow's post-actions then give the build to the Internal and Public TestFlight groups.
  2. Run `release/ship.sh` with an App Store Connect API key in the environment (the script's header lists what it
     needs). It waits up to 110 minutes for the hourly release to start the build and follows it until TestFlight has processed it. Then it adds the build to the Public
     group and submits the build for Beta App Review, unless the build is already submitted or an earlier build is
     still in review. It prints `SHIPPED PRHub build <n>`. `--dry-run` does the checks and stops.
  - With no PRHub Release workflow, or with `--local`, `release/ship.sh` archives and uploads the release on a Mac
    that can sign for the team. `release/ship.sh "<What to Test>"` with no release waiting ships the current HEAD
    with N from `next-build.sh` and makes no commit. `PRHUB_SUBMIT=NO` prevents the Beta App Review submission, but
    only in a local ship. In Xcode Cloud, the Public group's post-action can submit the build.
  - Xcode Cloud resolves packages only from a `Package.resolved`. `app/Package.resolved` pins the remote ones (PostHog)
    and `app/ci_scripts/ci_post_clone.sh` copies it into the generated project. When `project.yml`'s packages change,
    run `xcodebuild -resolvePackageDependencies` in `app/` and copy the project's `Package.resolved` back to `app/`.

### Setting up Xcode Cloud (once)

The Xcode Cloud product for PRHub must exist first. Xcode makes it, with GitHub access to `jai/prhub`. The App Store
Connect API cannot make a product.

1. Generate the project: `make -C app project`, then open `app/PRHub.xcodeproj` in Xcode.
2. **Product → Xcode Cloud → Create Workflow**, choose the PRHub app and grant access to `jai/prhub` when Xcode asks.
   Skip this step if App Store Connect → PRHub → Xcode Cloud already shows a product. Then check that GitHub sends
   pushes to Xcode Cloud: GitHub → **Settings → Applications → Xcode Cloud → Configure → Repository access** must
   include `jai/prhub`. The repo is public, so Xcode Cloud can clone it without this access, but it learns of the
   branch `ci/release`, where the hourly release builds, only from GitHub's push events.
3. Make the workflow. Either run `swift release/xcode-cloud.swift <key.p8> create-workflow` with `ASC_KEY_ID`,
   `ASC_ISSUER_ID` and `APP_BUNDLE_ID` set, or in Xcode's workflow editor set:
   - **General**: name `PRHub Release`, and select **Clean**. Put its id in `app/ci_scripts/workflows.sh`
     (`release_workflow`): `release.sh` and `release/xcode-cloud.swift` know it by that, so a rename breaks nothing.
   - **Environment**: Xcode version **Latest Release**.
   - **Start Conditions**: one **Manual Start** condition on the branches `main` and `ci/release`. Delete every other
     start condition: the hourly release starts it, never a push. Every PRHub workflow has only this condition.
   - **Actions**: one **Archive** action for iOS, scheme `PRHub`, deployment preparation **TestFlight and App Store**.
4. Add the post-actions. The API cannot add them, so use Xcode for this step. In **Product → Xcode Cloud → Manage
   Workflows**, edit **PRHub Release**:
   - **Post-Actions → + → TestFlight Internal Testing**, artifact **iOS**, group **Internal**.
   - **Post-Actions → + → TestFlight External Testing**, artifact **iOS**, group **Public**.
   - Enable the workflow if it is disabled. `release/ship.sh` ships locally while no enabled PRHub Release workflow
     exists.
5. Build numbers: App Store Connect → PRHub → **Xcode Cloud → Settings → Build Number**. Make sure **Next Build
   Number** is higher than TestFlight's highest PRHub build. `release/next-build.sh` reads both numbers.
6. Delete or disable any other workflow that archives PRHub, so that only a release commit makes a build.
