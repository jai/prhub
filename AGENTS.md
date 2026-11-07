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
  the app on a Simulator, on the sample PRs (`-PRHubFirstRun`, `-PRHubPaired`), with no Worker.
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

## Releases

- **PRKit**: tag `vX.Y.Z` on a green main. Apps pin it (`from: "0.1.0"`); Jai's Agent Pager is one of them.
- **PRHub**: `release/ship.sh "<What to Test>"` on a Mac that can sign for the team, with an App Store Connect API key
  in the environment (the script's header lists what it needs). It numbers the build one past App Store Connect's
  highest, uploads, waits for VALID, adds the build to the public TestFlight group and submits it for Beta App Review.
