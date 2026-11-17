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

## Cost

- Cloudflare: the Workers Free plan is enough for one person. The Worker uses Durable Objects with SQLite storage,
  which the free plan includes.
- R2: asks for billing details when you turn it on, even on the free plan. The diffs of one person's PRs fit in its
  free tier.
- Anthropic, if you turn on the AI features: model calls bill to your key. Ask AI stops a PR's session at $2.

## Develop

```sh
npm ci
npm test                    # All unit and integration tests
npm run test:unit           # Code-only Node tests, with in-memory dependency stubs
npm run test:integration    # Local SQLite/fixture tests, then workerd tests
npm run typecheck
npm run typecheck:test      # Test fixtures, runtime tests and Vitest configuration
```

Tests live in `test/unit/` and `test/integration/`, with shared builders in `test/support/`.
Unit tests do not open storage or make network requests. `test/integration/node/` covers SQL
with a fresh in-memory SQLite database per fixture and reads the shared PRKit contract files.
`test/integration/runtime/` uses Cloudflare's official Vitest plugin to run the production
Worker entrypoint and Durable Object classes in workerd, with local SQLite and R2 bindings.
It checks initialization, persisted receipts and events, HTTP authentication, and alarm cleanup.
Unexpected outbound requests fail through MSW; no Cloudflare account or deployment is needed.
Run those integration groups separately with `npm run test:integration:node` and
`npm run test:integration:runtime`. Runtime bindings are declared in `vitest.config.ts`;
they do not load the deployment configuration or launch agent containers.

After a deliberate change to what the Worker sends, `UPDATE_FIXTURES=1 npm test` rewrites `PRKit/Tests/PRContractFixtures/Fixtures/`, which
PRKit's tests decode; commit both. `deploy/setup.sh` renders `deploy/wrangler.template.jsonc` into
`deploy/wrangler.jsonc` (gitignored) and deploys it. The API is in [docs/api.md](../docs/api.md).
