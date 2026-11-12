# AGENTS.md

This repo is the source of PRHub: an iPhone app for reviewing GitHub pull requests, PRKit (the Swift package with its
PR screens), the Cloudflare Worker that each person deploys to their own account, and the push relay.

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
  `github-app/`), `docs/` (contracts, `fixtures/`, plans), `release/` (TestFlight), `scripts/` (repo checks).
- Contracts: [docs/api.md](docs/api.md) (pairing, `/device/config`, every var and secret) and
  [docs/push-relay.md](docs/push-relay.md). Whoever changes API behaviour updates the contract in the same commit.
- Tests: `npm test` and `npm run typecheck` in `worker/` and `relay/`. The worker's contract test compares what the
  real builders send with `docs/fixtures/*.json`; after a deliberate change run `UPDATE_FIXTURES=1 npm test` and
  commit the fixtures with the code.
- iOS: Swift 6, iOS 26, SwiftUI, Xcode 26. `swift test` for PRKit; `make -C app test` and `make -C app ui-test` for
  the app on a Simulator, on the sample PRs (`-PRHubFirstRun`, `-PRHubPaired`), with no Worker. Every UI test passes on
  an iPhone and on an iPad (`make -C app ui-test SIM_NAME='iPad Pro 13-inch (M5)'`; CI runs both): reach a tab with
  `app.go(to:)` in `UITestSupport.swift`, by accessibility identifier, never through `tabBars`.
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

One version for the repo, from conventional commits. release-please (`.github/workflows/release-please.yml`,
`release-please-config.json`) keeps one open release PR, `chore(release): PRHub X.Y.Z`, on `main`. `feat` bumps the
minor version, `fix` and `perf` the patch, and a `!` or `BREAKING CHANGE` the major. `feat`, `fix`, `perf` and
`revert` commits go in `CHANGELOG.md`; other types do not. Do not tag, edit `CHANGELOG.md` or change
`MARKETING_VERSION` by hand. release-please uses the workflow's token, so the repo's **Settings → Actions → General
→ Allow GitHub Actions to create and approve pull requests** must be on, and its release PR starts no CI runs.

- **PRKit**: each release's tag `vX.Y.Z` is PRKit's version. Apps pin it (`from: "0.1.0"`); Jai's Agent Pager is one
  of them.
- **PRHub**: the app's version (`MARKETING_VERSION` in `app/project.yml`) is the repo's version. The build number is
  set at ship time; `CURRENT_PROJECT_VERSION` in `app/project.yml` is not the shipped number.
  1. Merge the release PR. release-please sets `MARKETING_VERSION`, adds the version's section to `CHANGELOG.md`,
     tags `vX.Y.Z` and publishes the GitHub Release.
  2. Xcode Cloud's **PRHub Release** workflow starts on the tag. `app/ci_scripts` checks that the tag's version is
     `MARKETING_VERSION`, sets the build number to Xcode Cloud's (TestFlight shows that number), generates the
     project, archives and writes What to Test from the version's `CHANGELOG.md` section. The workflow's post-actions
     then give the build to the Internal and Public TestFlight groups.
  3. Run `release/ship.sh` with an App Store Connect API key in the environment (the script's header lists what it
     needs). It follows Xcode Cloud's build of the newest release tag until TestFlight has processed it. Then it adds
     the build to the Public group and submits the build for Beta App Review, unless the build is already submitted
     or an earlier build is still in review. It prints `SHIPPED PRHub <version> build <n>`. `--dry-run` does the
     checks and stops.
  - With no PRHub Release workflow, or with `--local`, `release/ship.sh` ships the newest release tag when TestFlight
    has no build of its version. It archives the tag's tree on a Mac that can sign for the team, with the build number
    from `release/next-build.sh`, and uploads it. `release/ship.sh "<What to Test>"` with no release waiting ships
    the current HEAD at `app/project.yml`'s version. `PRHUB_SUBMIT=NO` prevents the Beta App Review submission, but
    only in a local ship. In Xcode Cloud, the Public group's post-action can submit the build.
  - What to Test is the version's `CHANGELOG.md` section as plain text, cut to 4000 bytes
    (`release/what-to-test.sh`).
  - Xcode Cloud has no `Package.resolved` to read. PRKit is this repo's own package (`path: ..`) and `Package.swift`
    has no dependencies, so the project resolves with automatic resolution off. If a remote package is added, commit
    a `Package.resolved` and copy it into the generated project in `app/ci_scripts/ci_post_clone.sh`.
- **CI**: Linux jobs run on Ubicloud (`ubicloud-standard-2`), which needs the Ubicloud GitHub App on the `jai`
  account. macOS jobs run on GitHub's `macos-26`.

### Setting up Xcode Cloud (once)

The Xcode Cloud product for PRHub must exist first. Xcode makes it, with GitHub access to `jai/prhub`. The App Store
Connect API cannot make a product.

1. Generate the project: `make -C app project`, then open `app/PRHub.xcodeproj` in Xcode.
2. **Product → Xcode Cloud → Create Workflow**, choose the PRHub app and grant access to `jai/prhub` when Xcode asks.
   Skip this step if App Store Connect → PRHub → Xcode Cloud already shows a product. Then check that GitHub sends
   pushes to Xcode Cloud: GitHub → **Settings → Applications → Xcode Cloud → Configure → Repository access** must
   include `jai/prhub`. The repo is public, so Xcode Cloud can clone it and builds started by hand work without this
   access, but a push starts no build.
3. Make the workflow. Either run `swift release/xcode-cloud.swift <key.p8> create-workflow` with `ASC_KEY_ID`,
   `ASC_ISSUER_ID` and `APP_BUNDLE_ID` set, or in Xcode's workflow editor set:
   - **General**: name `PRHub Release` (`app/ci_scripts/release.sh` checks for this name), and select **Clean**.
   - **Environment**: Xcode version **Latest Release**.
   - **Start Conditions**: one **Tag Changes** condition on tags that begin with `v`. Delete every other start
     condition.
   - **Actions**: one **Archive** action for iOS, scheme `PRHub`, deployment preparation **TestFlight and App Store**.
4. Add the post-actions. The API cannot add them, so use Xcode for this step. In **Product → Xcode Cloud → Manage
   Workflows**, edit **PRHub Release**:
   - **Post-Actions → + → TestFlight Internal Testing**, artifact **iOS**, group **Internal**.
   - **Post-Actions → + → TestFlight External Testing**, artifact **iOS**, group **Public**.
   - Enable the workflow if it is disabled. `release/ship.sh` ships locally while no enabled PRHub Release workflow
     exists.
5. Build numbers: App Store Connect → PRHub → **Xcode Cloud → Settings → Build Number**. Make sure **Next Build
   Number** is higher than TestFlight's highest PRHub build. `release/next-build.sh` reads both numbers.
6. Delete or disable any other workflow that archives PRHub, so that only a release tag makes a build.
