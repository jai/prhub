# Deploying your own PRHub Worker

What PRHub is and what the Worker costs: [README.md](README.md).

For a coding agent setting up PRHub for its human. PRHub is an iPhone app for reviewing GitHub pull requests. You
deploy its backend, `worker/`, into your human's Cloudflare account, acting on GitHub with their own token. The app
pairs with the Worker you deploy. Nothing you deploy talks to Jai's Workers. The one shared service, optional, is Jai's
push relay, which sends your Worker's silent pushes to Apple.

Contracts: [docs/api.md](../docs/api.md) (pairing, config, every var and secret), [docs/push-relay.md](../docs/push-relay.md) (the relay).

## What you deploy

- One Cloudflare Worker with two Durable Objects (SQLite, free plan), one R2 bucket and a one-minute cron.
- It reads GitHub with one personal access token (PAT). No GitHub App is needed: the cron finds changes
  within about a minute. An optional webhook App makes it seconds ("Faster updates", below).
- Optional: an Anthropic API key, for key lines and description rewrites, and for Ask AI after one more script.
- Optional: push through Jai's relay, so the phone wakes for changes. Without it the app syncs when it is opened.
- Never on a self-hosted Worker: Feedback (Jai's own builder agent).

## Prerequisites

Ask your human for each of these. Never print or commit a secret. Pass secrets in the environment of one command.

1. **Cloudflare account** with a workers.dev subdomain and R2 enabled. A new account gets the subdomain when Workers &
   Pages is first opened in the dashboard. R2 is enabled once, in the dashboard under R2 (it asks for billing details
   even on the free tier).
   - **Account ID**: dashboard, Workers & Pages, right column, 32 hex characters.
   - **API token**: My Profile, API Tokens, Create Token, Custom token, scoped to that account, with: Account /
     Workers Scripts / Edit, Account / Workers R2 Storage / Edit, Account / Account Settings / Read. Add Account /
     Workers Tail / Read for `wrangler tail`.
2. **GitHub personal access token (classic), with an expiry**: GitHub, Settings, Developer settings, Personal access
   tokens, Tokens (classic), Generate new token (classic).
   - **Expiration**: 30 or 90 days. When it runs out, the human makes a new one and the agent replaces the secret
     (`wrangler secret put GITHUB_TOKEN`); no redeploy is needed.
   - **Scope**: `repo`. It covers every org the human belongs to and their own repos, private ones included: the
     lists, diffs, reviews, comments, statuses and merging.
   - **Org with SAML single sign-on**: after generating, choose Configure SSO next to the token and Authorize it for
     that org, or its private repos answer `404`.
   - A fine-grained token also works, with Repository permissions Pull requests (Read and write), Contents (Read;
     Read and write to merge), Commit statuses, Actions and Metadata (Read). It covers one resource owner only, and an
     org may hold it for an owner's approval. Fine-grained tokens have no Checks permission; check runs still read.
3. **Optional, an Anthropic API key** (console.anthropic.com), for key lines, rewrites and Ask AI. Model calls are
   billed to it; Ask AI caps each PR's session at $2.
4. **Optional, a relay key from Jai**, for push. The key starts `rks_`; Jai issues one per Worker: ask in an issue on [jai/prhub](https://github.com/jai/prhub/issues/new).
5. **On the machine you run from**: git, Node.js 24 or later with npm, `curl`, `jq`, bash. Optional: `qrencode`, to
   print the pairing link as a QR code.

## Steps

Run every command from the repo root. Each step has a check. Stop at the first check that fails and see
Troubleshooting.

### 1. Get the code

```sh
git clone https://github.com/jai/prhub.git && cd prhub
(cd worker && npm ci)
```

Check: `(cd worker && npm test)` reports `fail 0` in its closing summary.

### 2. Check the Cloudflare token

```sh
export CLOUDFLARE_ACCOUNT_ID=<account id>
read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN
printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" | curl -s --config - \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/subdomain" | jq '{success, subdomain: .result.subdomain}'
printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" | curl -s --config - \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/r2/buckets" | jq '.success'
```

Expected: `{"success": true, "subdomain": "<name>"}`, then `true`. The Worker will be at
`https://pr-review.<name>.workers.dev`.

### 3. Check the GitHub token

```sh
read -rs GITHUB_TOKEN && export GITHUB_TOKEN
gh_api() { printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" | curl -s --config - -H 'User-Agent: prhub-setup' "https://api.github.com$1"; }
gh_api /user | jq -r .login
gh_api '/search/issues?q=is:pr+is:open+review-requested:@me&per_page=1' | jq .total_count
```

Expected: the human's login, then a number (0 is fine). Then, for one repo they review in (`<owner>/<repo>`, a PR
`<n>` in it):

```sh
gh_api "/repos/<owner>/<repo>/pulls/<n>" | jq '{number, state}'
gh_api "/repos/<owner>/<repo>/commits/$(gh_api /repos/<owner>/<repo>/pulls/<n> | jq -r .head.sha)/check-runs?per_page=1" | jq .total_count
```

Expected: the PR, then a number. A `403` or `404` means the token lacks that repo or the `repo` scope. Pick a
private repo if the org has any, and check that private ones are in reach:

```sh
gh_api "/orgs/<owner>/repos?type=private&per_page=1" | jq length
```

Expected: `1` when the org has private repos. `0` (or only public repos above) means the org uses SAML single
sign-on and the token is not authorized for it (Configure SSO, Authorize), or, for a fine-grained token, that it was
made for another resource owner or waits for an org owner's approval.

### 4. Run setup

```sh
export GITHUB_ORGS=<owner>[,<owner>]      # optional: the app's default filter
export PUSH_RELAY_URL=https://agent-pager-relay.jai-f89.workers.dev; read -rs PUSH_RELAY_KEY && export PUSH_RELAY_KEY   # optional
read -rs ANTHROPIC_API_KEY && export ANTHROPIC_API_KEY                                        # optional
worker/setup.sh
```

Optional settings: `WORKER_NAME` (default `pr-review`), and a review SLA week: `REVIEW_SLA_UTC_OFFSET_HOURS` (`7`),
`REVIEW_SLA_HOURS` (`9-18`), `REVIEW_SLA_WEEKDAYS` (`1,2,3,4,5`, Sunday is 0), which gives each PR waiting on the
human a due time one working day out.

What it does: checks both tokens, finds or creates the R2 bucket `<worker>-diffs`, writes
`worker/wrangler.jsonc` (gitignored), deploys, sets each secret given (`GITHUB_TOKEN`, `PUSH_RELAY_KEY`,
`ANTHROPIC_API_KEY`, `ASK_GITHUB_TOKEN`), checks the Worker, and prints a pairing link. It is safe to run again: a
secret not given is kept, and a new run prints a new code. Give it the same optional vars each run, because the
config is rendered again from them.

Expected at the end:

```
==> the Worker answers

Pairing code 7KQ2-M9XA (device),
single use, valid until 2026-11-06T15:30:00.000Z. Open this link on the iPhone, or scan the QR code:

prhub://setup?worker=https%3A%2F%2Fpr-review.<name>.workers.dev&code=7KQ2M9XA
```

### 5. Check the Worker as an app

Pair a throwaway device secret from the shell, read through it, and unpair it. `--app` adds a device without
replacing the phone.

```sh
URL=https://pr-review.<name>.workers.dev
(cd worker && npm run pair -- --worker $URL --app cli --config wrangler.jsonc)
SECRET=$(openssl rand -hex 32)
auth() { printf 'header = "Authorization: Bearer %s"\n' "$SECRET"; }
auth | curl -s --config - -H 'content-type: application/json' -d '{"code":"<code it printed>"}' $URL/device/pair | jq .role
auth | curl -s --config - $URL/device/config | jq
until [ "$(auth | curl -s --config - $URL/prs | jq .synced_at)" != 0 ]; do sleep 30; done
auth | curl -s --config - $URL/prs | jq '{rows: (.prs | length), synced_at}'
auth | curl -s --config - -o /dev/null -w '%{http_code}\n' -X DELETE $URL/device/pair
```

Expected: `"app"`; the config with `login` set and each feature as configured ([docs/api.md](../docs/api.md)); after the
first cron run, `synced_at` not 0 and the human's open PRs counted; `204`. A new Worker's cron can take several
minutes to fire the first time (10 on a test deploy), so the loop may wait that long.

### 6. Pair the phone

The human installs PRHub from its TestFlight link ([README.md](../README.md#install-the-app)) and opens the link from step 4 on the iPhone, or scans
the QR code in the app. Codes last 30 minutes. Mint another:

```sh
(cd worker && npm run pair -- --worker $URL --config wrangler.jsonc)
```

A code without `--app` makes that phone the Worker's one device: it replaces every device paired before it.

Check: the PRs tab lists the same PRs as step 5.

### 7. Optional: Ask AI

Ask AI runs a Claude Managed Agents session per PR, in the human's Anthropic org. Make its agent, environment and
vault once, then pass the ids to setup:

```sh
(cd worker && npm run ask-agent)      # uses ANTHROPIC_API_KEY and GITHUB_TOKEN from the environment
```

It prints `{"ASK_AGENT_ID": …, "ASK_ENVIRONMENT_ID": …, "ASK_VAULT_ID": …, "ASK_CREDENTIAL_ID": …}`. Export the four,
and preferably a second, read-only token as `ASK_GITHUB_TOKEN` (a classic token cannot be read only for private
repos, so this one is fine-grained: Metadata, Pull requests, Contents, Commit statuses, Actions, all Read), so the agent never holds the write token. Without it the agent
gets `GITHUB_TOKEN`. Run `worker/setup.sh` again.

Check: `/device/config` shows `"ask_ai": true`. Each run of the script creates new resources: run it once.

### Faster updates (optional webhook App)

The poll is enough. For updates within seconds, make a GitHub App that only sends webhooks; the Worker still reads
with the PAT.

```sh
STATE=$(openssl rand -hex 16)
printf '%s' "$STATE" | (cd worker && npx wrangler@4 secret put SETUP_STATE --config wrangler.jsonc)
echo "$URL/github/setup?state=$STATE"
```

Set `GITHUB_APP_OWNER` in `worker/wrangler.template.jsonc` to the org first (empty makes it on the
human's own account) and `GITHUB_APP_NAME` to a name not taken on GitHub (empty: `<login>-pr-review`), then run
`worker/setup.sh` again.
The human opens the printed link, creates the App and installs it on the repos. Then set its webhook secret without
printing it, and drop what GitHub returned:

```sh
cd worker
B=<worker>-diffs C=wrangler.jsonc
npx wrangler@4 r2 object get "$B/setup/github-app.json" --remote --pipe --config $C | jq -j .webhook_secret \
  | npx wrangler@4 secret put WEBHOOK_SECRET --config $C
npx wrangler@4 r2 object delete "$B/setup/github-app.json" --remote --config $C
npx wrangler@4 secret delete SETUP_STATE --config $C
```

Check: `/device/config` shows `"webhooks": true`, and a comment on a PR shows in the app within seconds.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Step 2: `success: false`, code 10000 | The token lacks a permission or is scoped to another account | Recreate it with the permissions above |
| Step 2: R2 answers `success: false` | R2 is not enabled on the account | Enable R2 in the dashboard once, re-run |
| `GitHub did not accept GITHUB_TOKEN` | Expired, revoked, or pending org approval | Make a new token, or ask the org owner to approve it |
| `/prs` stays empty after a few minutes | The token cannot see the repos | Check `/events` for `poll_failed`; widen the token's repository access |
| Only public repos answer; private ones `404` | The org uses SAML SSO and the token is not authorized for it; or a fine-grained token was made for another owner, or waits for approval | Authorize the token for the org (Configure SSO), or remake it (step 3); no redeploy needed |
| A write answers `403 Resource not accessible by personal access token` | A permission is missing (merge needs Contents write) | Edit the token's permissions; no redeploy needed |
| `/device/pair` answers `pairing_code_invalid` | The code is used, expired or mistyped | Mint a new one (step 6) |
| A paired app gets `401` | Another phone was paired without `--app`, replacing it | Pair it again with `--app "<label>"` |
| Push events show `relay_unauthorized` | The relay key is wrong or revoked | Ask Jai for a new key; re-run setup with it |
| Key lines or rewrite answer `404 … not set up` | No `ANTHROPIC_API_KEY` | Re-run setup with it |
| Ask AI answers `404 … not set up` | The four `ASK_*` ids or the key are missing | Step 7 |

Logs: `cd worker && npx wrangler@4 tail <worker name> --config wrangler.jsonc --format pretty`.

## What to tell your human

- The Worker URL, that it is on their Cloudflare account, and that it acts on GitHub as them, with their PAT.
- Which optional features are on (`/device/config`), and what each needs to turn on.
- That push, if on, goes through Jai's relay, which forwards each wake to Apple and keeps nothing.
