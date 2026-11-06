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
Deploy PRHub's worker by following worker/AGENTS.md in github.com/jai/prhub
```

The agent asks you for each token and key. Then it deploys the Worker, checks each step, and prints a pairing link
and a QR code.

For what the Worker does and what it costs, read [worker/README.md](worker/README.md).

## Install the app

> 🚧 Coming soon: PRHub is not on TestFlight yet. Its public TestFlight link goes here: `TESTFLIGHT_PUBLIC_LINK`.

## Pair the app

Open PRHub and scan the QR code that your agent printed. Or open the `prhub://setup?...` link on your iPhone. A
pairing code works once and expires after 30 minutes. For a new code, ask your agent.

## Privacy

Your Worker, your token and your PR data stay in your Cloudflare account. The Worker sends data only to GitHub, and to
Anthropic when the AI features are on. Only push goes through Jai: your Worker sends each silent push through Jai's
relay to Apple. A push carries your phone's push token and the text `pr_sync`, and no PR content. The relay stores no
push token and no message. It logs each push with your relay key's ID and Apple's answer.

## License

[MIT](LICENSE)
