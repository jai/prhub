# Distribution: PRHub for other people

Status: decided 2026-11-06; built. Since 2026-11-07 this repo is the source of PRKit, the app, the Worker and the
relay; Jai's Agent Pager consumes PRKit as a Swift package from here.

## Goal

Someone else reviews their GitHub PRs on their iPhone with PRHub, and has their own coding agent deploy the backend
for them. Nothing of theirs reaches Jai's Workers or accounts, and nothing of Jai's reaches theirs.

## Shape

- **One public app, PR review only: PRHub.** Extracted from Agent Pager's PRs tab. Bundle ID
  `com.jaigovindani.prreview`, team `K2P9X73SPT`, App Store Connect app `6831601628`, URL scheme `prhub`, shared by
  TestFlight public link. Jai's own Agent Pager app stays a separate app that embeds PRKit as its PRs tab.
- **Each person runs their own `worker/`** (Cloudflare, free plan plus R2) with their own GitHub fine-grained PAT.
  No GitHub App is needed: the one-minute poll finds changes. An optional webhook App, made on their org or account
  from the Worker's own `/github/setup`, brings that to seconds. Their agent deploys it from `deploy/` by
  following one guide written for agents.
- **The app learns its Worker at first run** from a `prhub://setup?worker=…&code=…` link or QR code that the
  Worker's `npm run pair` prints: Worker URL plus a one-time pairing code. The app's device secret is then its bearer.
- **Push goes through Jai's relay.** An APNs key is per team, so a person's Worker cannot push to an app on Jai's
  team. It sends each silent wake to the relay (`relay/`), whose topic is PRHub's bundle ID. Optional: without it the
  app syncs when opened.
- **Features follow the Worker** (`GET /device/config`): Ask AI, key lines and rewrites with the person's own
  Anthropic key; Feedback is Jai's and is never on elsewhere.

## Work, in order

1. **Worker** (done, 2026-11-06). Login from the token, pairing and device auth, `/device/config`, relay push, Ask AI
   on a PAT, the review SLA and writing guide as vars, webhooks optional. Contract: `docs/api.md`. Jai's
   own deployment keeps `APP_TOKEN` and his values in his private config.
2. **Self-host package** (done): `deploy/` — template, `setup.sh`, `AGENTS.md`.
3. **The app** (built, 2026-11-06; build 3 on TestFlight, 2026-11-07). `app/`, PRHub's own Xcode project over
   PRKit: its composition root with the PR screens and a Settings screen alone,
   onboarding (open or scan the setup link, URL and device secret in the keychain, `POST /device/pair`, `DELETE` on
   Disconnect), the device secret as bearer, Ask AI, key lines and Rewrite from `/device/config`, the org filter's
   default from `orgs` (else every owner), and push registered with the pr-worker when `push` is on. Its own
   entitlements (push and its keychain group; no HealthKit, Time Sensitive or shared group), name, placeholder icon
   and `prhub` scheme; no widget, notification service or background audio.
   "Try with sample PRs" on onboarding runs the PR screens on made-up PRs with no Worker and sends nothing
   (`PRHubSamples.swift`), for App Review and for anyone without a pr-worker yet.
4. **Relay** for PRHub: `APNS_TOPIC` `com.jaigovindani.prreview`, and per-Worker keys issued at setup.
5. **App Store Connect** (2026-11-07). External group "Public" with the public link
   https://testflight.apple.com/join/SG8nZjVa (limit 1000), build 3 in it and submitted for Beta App Review. Privacy
   policy: https://github.com/jai/prhub/blob/main/PRIVACY.md. The
   review notes send the reviewer to "Try with sample PRs".
6. **End-to-end check.** A fresh Cloudflare account and a fresh PAT, deployed by an agent from the guide alone,
   paired with PRHub from TestFlight, listing and reviewing a PR, and woken by a push.
