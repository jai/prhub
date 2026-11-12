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
- Checks a PR needs green before it merges: the Linux jobs on Ubicloud (`scrub`, `worker` and `relay` on every PR;
  `design` when PRKit, the app or DESIGN.md change), and, for a PR that touches `app/`, `PRKit/` or `docs/fixtures/`,
  Xcode Cloud's PRHub Tests (`PRHub | PRHub Tests | Test - iOS`): PRKit's `swift test`, then the PRHub scheme's unit
  and UI tests on an iPhone and a 13-inch iPad Pro. It reports only for those paths: a PR that changes only
  `Package.swift` or `DESIGN.md` starts it by hand (App Store Connect → PRHub → Xcode Cloud, or the API on a `main`
  or `ci/…` branch).
  The scripts in `app/ci_scripts` know each workflow by its id (`workflows.sh`), never its name.
- Tests: `npm test` and `npm run typecheck` in `worker/` and `relay/`. The worker's contract test compares what the
  real builders send with `docs/fixtures/*.json`; after a deliberate change run `UPDATE_FIXTURES=1 npm test` and
  commit the fixtures with the code.
- iOS: Swift 6, iOS 26, SwiftUI, Xcode 26. `swift test` for PRKit; `make -C app test` and `make -C app ui-test` for
  the app on a Simulator, on the sample PRs (`-PRHubFirstRun`, `-PRHubPaired`), with no Worker. Every UI test passes on
  an iPhone and on an iPad (`make -C app ui-test SIM_NAME='iPad Pro 13-inch (M5)'`; Xcode Cloud's PRHub Tests
  workflow runs both): reach a tab with `app.go(to:)` in `UITestSupport.swift`, by accessibility identifier, never
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

- **PRKit**: tag `vX.Y.Z` on a green main. Apps pin it (`from: "0.1.0"`); Jai's Agent Pager is one of them.
- **PRHub on every push**: Xcode Cloud's **Internal - TestFlight** workflow archives each push to `main` and gives it
  to the Internal TestFlight group, with the commit's subject as What to Test. Xcode Cloud numbers the build itself;
  its **Next Build Number** (App Store Connect → PRHub → Xcode Cloud → Settings) must stay above TestFlight's highest
  build, or the upload is refused. Nothing to run.
- **PRHub for the Public group**: a release is one commit on `main` that sets `CURRENT_PROJECT_VERSION` in `app/project.yml` to N, with
  the subject `chore(release): PRHub build N — <What to Test>`. Take N from `release/next-build.sh`, change nothing
  else in that commit, and change `CURRENT_PROJECT_VERSION` in no other commit.
  1. Push the release commit to `main`. Xcode Cloud's **PRHub Release** workflow starts on any change to
     `app/project.yml` on `main`. `app/ci_scripts` checks that the change is a release, sets the build number to
     Xcode Cloud's (TestFlight shows that number), generates the project, archives and writes What to Test from the
     subject. The workflow's post-actions then give the build to the Internal and Public TestFlight groups.
  2. Run `release/ship.sh` with an App Store Connect API key in the environment (the script's header lists what it
     needs). It follows Xcode Cloud's build until TestFlight has processed it. Then it adds the build to the Public
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
   include `jai/prhub`. The repo is public, so Xcode Cloud can clone it and builds started by hand work without this
   access, but a push starts no build.
3. Make the workflow. Either run `swift release/xcode-cloud.swift <key.p8> create-workflow` with `ASC_KEY_ID`,
   `ASC_ISSUER_ID` and `APP_BUNDLE_ID` set, or in Xcode's workflow editor set:
   - **General**: name `PRHub Release`, and select **Clean**. Put its id in `app/ci_scripts/workflows.sh`
     (`release_workflow`): `release.sh` and `release/xcode-cloud.swift` know it by that, so a rename breaks nothing.
   - **Environment**: Xcode version **Latest Release**.
   - **Start Conditions**: one **Branch Changes** condition on the branch `main`. Set **Files and Folders** to
     **Any File Matches**, with the file `app/project.yml`. Delete every other start condition.
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
