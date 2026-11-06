# AGENTS.md

This repo holds PRHub's backend: a Cloudflare Worker that a person deploys to their own Cloudflare account. PRHub is
an iPhone app for reviewing GitHub pull requests, and it talks only to that Worker.

## If you were asked to deploy PRHub

Follow [worker/AGENTS.md](worker/AGENTS.md). It is the whole deployment guide: prerequisites, each step with a check,
pairing the phone, and troubleshooting.

## Rules

- Never print, log or commit a secret. Pass each secret in the environment of one command, as the guide does.
- Ask your human for the Cloudflare API token, the GitHub token and any optional key. Do not make or reuse one
  yourself.
- Run each step's check before the next step. Stop at the first check that fails and use the guide's
  Troubleshooting table.

## Where the code comes from

The code is exported from Jai Govindani's private repo, `jai/agent-pager`, so paths in code comments can name files
that are not here. A change made here is overwritten by the next export: do not open pull requests. Open an issue
for a bug or a question.

Contracts: [docs/api.md](docs/api.md) (pairing, `/device/config`, every var and secret) and
[docs/push-relay.md](docs/push-relay.md) (the shared push relay).
