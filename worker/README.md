# PRHub Worker

The backend for [PRHub](../README.md), deployed to your own Cloudflare account. To deploy it, have your coding agent
follow [deploy/AGENTS.md](../deploy/AGENTS.md), the deployment guide.

## What it does

- Keeps a copy of your open PRs: the ones waiting on your review, your own, and the ones you reviewed.
- Checks GitHub every minute with your personal access token (PAT). An optional GitHub App sends
  webhooks, so updates arrive in seconds.
- Stores each PR's diff in R2 (Cloudflare's object storage) and serves it to the app.
- Sends your reviews, comments and merges to GitHub as you, with your PAT.
- With an Anthropic API key: picks the key lines of a diff, rewrites PR descriptions, and runs Ask AI.
- With a relay key: wakes the app with a silent push when a PR changes.

## Cost

- Cloudflare: the Workers Free plan is enough for one person. The Worker uses Durable Objects with SQLite storage,
  which the free plan includes.
- R2: asks for billing details when you turn it on, even on the free plan. The diffs of one person's PRs fit in its
  free tier.
- Anthropic, if you turn on the AI features: model calls bill to your key. Ask AI stops a PR's session at $2.

## Develop

```sh
npm ci
npm test            # node:test, including the contract test that checks docs/fixtures/
npm run typecheck
```

After a deliberate change to what the Worker sends, `UPDATE_FIXTURES=1 npm test` rewrites `docs/fixtures/`, which
PRKit's tests decode; commit both. `deploy/setup.sh` renders `deploy/wrangler.template.jsonc` into
`deploy/wrangler.jsonc` (gitignored) and deploys it. The API is in [docs/api.md](../docs/api.md).
