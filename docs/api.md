# PRHub: a self-hosted PR Worker

Implemented in [worker/](../worker/). The deployment guide is [worker/AGENTS.md](../worker/AGENTS.md).

PRHub is the public PR-review app (bundle ID `com.jaigovindani.prreview`, URL scheme `prhub`). Its backend is `worker/`, the same code as Jai's `pr-viewer` Worker, deployed
into each person's own Cloudflare account and acting on GitHub with their own token. What differs from Jai's Worker:

- **Auth.** The app pairs with a one-time code (below) and then sends its own device secret as the bearer. Jai's
  Worker keeps `APP_TOKEN`, which his app reads from the Pager Worker's `GET /device/pr-viewer-token`. A Worker
  accepts both; an unset `APP_TOKEN` or `HUB_TOKEN` admits nobody.
- **Identity.** `GITHUB_LOGIN` is optional: unset, the Worker reads the token's user (`GET /user`) once per isolate.
- **Features follow the configuration** (`GET /device/config`).
- **Push** goes through Jai's relay ([push-relay.md](push-relay.md)) when `PUSH_RELAY_URL` and `PUSH_RELAY_KEY` are set;
  the relay's topic is PRHub's bundle ID.

Every other route (`/prs`, `/prs/merged`, `/prs/{owner}/{repo}/{n}/…`, `/device/register`, `/device/event`,
`/push-state`, `/events`) is unchanged and takes either bearer.

## Pairing

### The setup link

`npm run pair -- --worker <url> [--app "<label>"] --config <wrangler config>` (from `worker/`;
`worker/setup.sh` runs it last) prints:

```
prhub://setup?worker=https%3A%2F%2Fpr-review.alex.workers.dev&code=7KQ2M9XA
```

- `worker`: the Worker's base URL, percent-encoded, `https://<host>` with no path or trailing slash.
- `code`: 8 characters of Crockford base32 (`0-9`, `A-Z` without `I`, `L`, `O`, `U`), shown to people as
  `7KQ2-M9XA`. Single use; expires 30 minutes after it is minted.
- With `qrencode` on the PATH, the same link is printed as a terminal QR code.

The app opens on the link (or a scanned QR code, or the two values pasted), makes a device secret (16–512
characters, kept in the keychain with the URL), and pairs.

### `POST /device/pair`

Auth: `Authorization: Bearer <device secret>`. The secret need not be known yet: pairing makes it known.

```json
{ "code": "7KQ2M9XA" }
```

`code` is matched without regard to case, spaces or hyphens.

`200`:

```json
{ "role": "device", "fingerprint": "<64 lowercase hex>", "label": null }
```

- `fingerprint` is the SHA-256 of the secret's UTF-8 bytes.
- `role: "device"`: this secret is now the Worker's one paired device. Every secret paired before it stops working,
  and every push registration is dropped; the app then calls `POST /device/register` as usual.
- `role: "app"`: this secret is added beside the others (minted with `--app "<label>"`: an iPad, a Mac, a shell
  check). `label` is that label.

Errors, each `{"error": {"code", "message"}}`:

| Status | `code` | When |
|---|---|---|
| 400 | `validation_error` | `code` is missing or is not 8 characters of the alphabet |
| 401 | `unauthorized` | No bearer, or one outside 16–512 characters |
| 401 | `pairing_code_invalid` | The code is unknown, already used or expired; one message for all three |

The app does not retry a `401`: it asks for a new code. A paired secret works at once, everywhere.

### `DELETE /device/pair`

Auth: a paired secret. Forgets that secret; `204`. Other paired secrets keep working. Takes up to 60 s to reach every
isolate.

### What it writes

- `npm run pair` puts `pair/<sha256 hex of the code>.json` = `{role, label, created_at, expires_at}` in the Worker's
  R2 bucket (the one bound as `DIFFS`), with `wrangler r2 object put` and the operator's Cloudflare token. Only
  someone who can write the bucket can mint a code. The code itself is never stored.
- `POST /device/pair` spends the code in the PR index Durable Object before reading the record, so a code admits one
  secret even under concurrent requests. It then deletes the record and stores the fingerprint. A guess that matches
  no record spends nothing.

## `GET /device/config`

Auth: a paired secret or `APP_TOKEN`. `Cache-Control: no-store`. The app reads it at launch and on foreground.

```json
{
  "features": {
    "ask_ai": true,
    "key_lines": true,
    "rewrite": true,
    "feedback": false,
    "push": true,
    "webhooks": false
  },
  "login": "alex",
  "orgs": ["acme"]
}
```

| Field | True when | The app |
|---|---|---|
| `features.ask_ai` | `ASK_AGENT_ID`, `ASK_ENVIRONMENT_ID`, `ASK_VAULT_ID`, `ASK_CREDENTIAL_ID` and a key (`ASK_ANTHROPIC_API_KEY` or `ANTHROPIC_API_KEY`) | Shows Ask on a PR and a line |
| `features.key_lines` | `ANTHROPIC_API_KEY` | Shows the Key lines panel and capsule |
| `features.rewrite` | `ANTHROPIC_API_KEY` | Shows Rewrite on the description |
| `features.feedback` | `FEEDBACK_AGENT_ID`, `FEEDBACK_ENVIRONMENT_ID`, `ASK_ANTHROPIC_API_KEY`: Jai's Worker only | Shows Feedback |
| `features.push` | the relay (`PUSH_RELAY_URL`, `PUSH_RELAY_KEY`), or direct APNs (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `APNS_BUNDLE_ID`) | Registers for push; off: syncs on open and foreground only |
| `features.webhooks` | `WEBHOOK_SECRET` | Diagnostics only: updates in seconds rather than about a minute |
| `login` | the GitHub login the Worker acts as; `null` if GitHub could not be asked | "Your PRs", and whose review a row shows |
| `orgs` | `GITHUB_ORGS`, comma-separated; absent when unset | The PR filter's default selection |

A key the app does not know is ignored; a feature the Worker does not send is off. Routes for a feature that is off
answer `404 {"error": "<feature> is not set up on this Worker."}`. Answers: `200` · `401`.

## Configuration

Required: `GITHUB_TOKEN` (secret), and the `DIFFS` R2 bucket, `PR_INDEX` and `AI_JOBS` Durable Objects and the
one-minute cron, as `worker/wrangler.template.jsonc` binds them. Everything else is optional; an empty
var reads as unset.

| Name | Kind | Value |
|---|---|---|
| `GITHUB_TOKEN` | secret | The person's fine-grained PAT (permissions in [worker/AGENTS.md](../worker/AGENTS.md)) |
| `GITHUB_LOGIN` | var | Their login; unset reads it from the token |
| `GITHUB_ORGS` | var | Default filter for the app |
| `PUSH_RELAY_URL` | var | Jai's relay base URL |
| `PUSH_RELAY_KEY` | secret | This Worker's relay key, `rks_…` |
| `ANTHROPIC_API_KEY` | secret | Key lines, rewrites; Ask's key when `ASK_ANTHROPIC_API_KEY` is unset |
| `ASK_AGENT_ID`, `ASK_ENVIRONMENT_ID`, `ASK_VAULT_ID`, `ASK_CREDENTIAL_ID` | var | From `npm run ask-agent` |
| `ASK_GITHUB_TOKEN` | secret | A read-only PAT for Ask's agent; unset, it gets `GITHUB_TOKEN` |
| `ASK_GITHUB_APP_ID`, `ASK_GITHUB_APP_KEY` | secret | A GitHub App that mints a read-only token per question; wins over the PATs |
| `GUIDE_REPO`, `GUIDE_FILES` | var | The rewrite's writing guide: `owner/repo@ref` (no ref: default branch) and comma-separated paths. Unset: a built-in guide |
| `REVIEW_SLA_UTC_OFFSET_HOURS`, `REVIEW_SLA_HOURS`, `REVIEW_SLA_WEEKDAYS` | var | The review SLA week, e.g. `7`, `9-18`, `1,2,3,4,5` (Sunday 0). Unset: no row has `reviewDueAt` |
| `WEBHOOK_SECRET` | secret | Turns on `/github/webhook`; unset, it answers 404 |
| `SETUP_STATE` | secret | Turns on `/github/setup` and `/github/callback` for making a webhook App |
| `GITHUB_APP_OWNER`, `GITHUB_APP_NAME` | var | The org that owns the webhook App (unset: the person's account) and its name (unset: `<login>-pr-review`) |
| `PR_INDEX_LOCATION` | var | Durable Object location hint for the index |
| `APP_TOKEN`, `HUB_TOKEN`, `APNS_*`, `FEEDBACK_*`, `LINEAR_API_KEY` | | Jai's Worker; not set on a self-hosted one (`LINEAR_API_KEY` works for anyone with Linear) |

The webhook App's manifest points at the origin `/github/setup` was opened on, so it is right on any Worker. Its
credentials stay in R2 at `setup/github-app.json` until read once (`POST /github/app-credentials`, or
`wrangler r2 object get` as the guide does).

Push through the relay sends the same silent wake as direct APNs (`push_type` `background`, priority 5,
`collapse_id` `pr-sync`, 30-minute expiry, payload `{"aps": {"content-available": 1}, "reason": "pr_sync"}`). A push
the relay refuses is recorded in `/events` with `status: null` and `reason` `relay_unauthorized`,
`relay_rate_limited`, `relay_rejected`, `relay_http_<status>` or `relay_bad_response`; a network failure is
`fetch_error: network` or `fetch_error: timeout`.
