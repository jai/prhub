# PRHub

> Review your GitHub pull requests on iPhone, from a Worker in your own Cloudflare account.

PRHub is an iPhone app for reviewing GitHub pull requests (PRs). It shows:

- Your PR lists: the PRs that wait on your review, and your own open PRs.
- Each PR's diff, with its checks and review state.
- Key lines: the changed lines to read first.
- Ask AI: questions about a PR or a line, answered by Claude with the repo checked out.
- Reviews: approve, request changes, comment on a line, reply, resolve threads and merge.

The app talks only to its backend, a Cloudflare Worker that you deploy to your own Cloudflare account. The Worker acts
on GitHub with your own token. Your coding agent deploys it for you.

## What you need

- A Cloudflare account with R2 (Cloudflare's object storage) turned on. The free plan is enough. R2 asks for billing
  details when you turn it on, even on the free plan.
- A GitHub personal access token (PAT, classic) with the `repo`, `workflow` and `read:org` scopes and an expiry, such
  as 90 days. It covers every org you belong to and your own repos.
- Optional: an Anthropic API key, for key lines, description rewrites and Ask AI. Model calls bill to your key.
- Optional: a relay key from Jai, for push. With push, the app updates when a PR changes. Without push, the app
  updates when you open it. To get a key, [open an issue](https://github.com/jai/prhub/issues/new).
- A coding agent, such as Claude Code or Codex, on a computer with git, Node.js 24 or later, curl and jq.

## Deploy the Worker

Tell your agent:

```text
Deploy PRHub's worker by following deploy/AGENTS.md in github.com/jai/prhub
```

The agent asks you for each token and key. Then it deploys the Worker, checks each step, and prints a pairing link
and a QR code.

For what the Worker does and what it costs, read [worker/README.md](worker/README.md).

## Install the app

Install PRHub with TestFlight, Apple's app for beta apps: <https://testflight.apple.com/join/SG8nZjVa>. The link
works after Apple's beta review approves PRHub.

To look around before you deploy a Worker, tap **Try with sample PRs** on the app's first screen. The sample PRs
are made up, and nothing that you do with them reaches GitHub.

## Pair the app

Open PRHub and scan the QR code that your agent printed. Or open the `prhub://setup?...` link on your iPhone. A
pairing code works once and expires after 30 minutes. For a new code, ask your agent.

## What's here

- `app/`: the PRHub iPhone app (XcodeGen, `app/project.yml`): pairing, Settings and the sample PRs around PRKit.
- `PRKit/` and `Package.swift`: PRKit, the Swift package with the PR screens, their models and the Worker client
  ([PRKit/README.md](PRKit/README.md)). Other apps add this repo as a package and embed the screens as one tab.
- `worker/`: the Worker each person deploys. `deploy/` has its template, `setup.sh` and the agent's deployment guide.
- `relay/`: the push relay that Jai runs, which forwards silent pushes to Apple ([docs/push-relay.md](docs/push-relay.md)).
- `docs/`: the Worker's API ([docs/api.md](docs/api.md)), the fixtures the app's tests decode, and plans.
- `release/`: `ship.sh`, which uploads a TestFlight build. `DESIGN.md`: the app's design tokens and parts.

## Build and test

```sh
(cd worker && npm ci && npm test && npm run typecheck)
(cd relay && npm ci && npm test && npm run typecheck)
swift test                 # PRKit, on macOS
make -C app test           # the app's and PRKit's unit tests on an iOS Simulator (Xcode 26, XcodeGen)
make -C app ui-test        # the samples flow, and pictures of every screen in app/build/screenshots
scripts/scrub.sh           # fails if a private name or value is in the repo
```

CI runs these on every push and pull request, and a nightly end-to-end check against a test Worker. The app's tests
need no Worker and no secrets: they run on the sample PRs.

## Use PRKit in your app

```swift
.package(url: "https://github.com/jai/prhub", from: "0.1.0")
```

Add the `PRKit` product to the app target, then follow [PRKit/README.md](PRKit/README.md).

## Privacy

Your Worker, your token and your PR data stay in your Cloudflare account. The Worker sends data only to GitHub, and to
Anthropic when the AI features are on. Only push goes through Jai: your Worker sends each silent push through Jai's
relay to Apple. A push carries your phone's push token and the text `pr_sync`, and no PR content. The relay stores no
push token and no message. It logs each push with your relay key's ID and Apple's answer.

The full policy is in [PRIVACY.md](PRIVACY.md). The hosted service, which you reach with Sign in with GitHub, has its
own: [docs/privacy/hosted.md](docs/privacy/hosted.md).

## License

[MIT](LICENSE)
