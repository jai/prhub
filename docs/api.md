# PRHub: a self-hosted PR Worker

Implemented in [worker/](../worker/). The deployment guide is [deploy/AGENTS.md](../deploy/AGENTS.md).

PRHub is the public PR-review app (bundle ID `com.jaigovindani.prreview`, URL scheme `prhub`). Its backend is `worker/`, the same code as Jai's `pr-viewer` Worker, deployed
into each person's own Cloudflare account and acting on GitHub with their own token. What differs from Jai's Worker:

- **Auth.** The app pairs with a one-time code (below) and then sends its own device secret as the bearer. Jai's
  Worker keeps `APP_TOKEN`, which his app reads from the Pager Worker's `GET /device/pr-viewer-token`. A Worker
  accepts both; an unset `APP_TOKEN` or `HUB_TOKEN` admits nobody.
- **Identity.** `GITHUB_LOGIN` is optional: unset, the Worker reads the token's user (`GET /user`) once per isolate.
- **Features follow the configuration** (`GET /device/config`).
- **Push** goes through Jai's relay ([push-relay.md](push-relay.md)) when `PUSH_RELAY_URL` and `PUSH_RELAY_KEY` are set;
  the relay's topic is PRHub's bundle ID.

The hosted Worker, which everyone signs in to with GitHub, is the same code with `HOSTED=on`:
[Hosted sign-in](#hosted-sign-in).

Every other route (`/prs`, `/prs/merged`, `/prs/{owner}/{repo}/{n}/…`, `/repos`, `/device/register`, `/device/event`,
`/push-state`, `/events`) takes either bearer. Quick jump and alerts are below.

Request bodies are parsed where they arrive (`worker/src/boundary.ts`); one that is not JSON, or not the route's
shape, answers `400`, and nothing of it is kept. `POST /device/register` takes `{"token": "<APNs token, hex>", "host":
"production" | "sandbox"}` and keeps the token lowercased; any other token (one the relay would refuse on every push)
answers `400 {"error": {"code": "validation_error", "message"}}`. `POST /device/event` takes an object with a `kind`
(1–64 characters) and, when sent, `changed` as a list of PR ids and `complete` as a boolean; the same `400` otherwise.

## Pairing

### The setup link

`npm run pair -- --worker <url> [--app "<label>"] --config <wrangler config>` (from `worker/`;
`deploy/setup.sh` runs it last) prints:

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

Auth: a paired secret. Forgets that secret; `204`. Other paired secrets keep working. The next request with it answers
`401`, on every isolate: a paired secret is checked with the PR index on each request.

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
  "orgs": ["acme"],
  "ai": {
    "features": {
      "key_lines": {
        "default": { "model": "claude-sonnet-5-5", "effort": "high" },
        "allowed": [
          { "model": "claude-haiku-5-5", "label": "Haiku 5.5", "efforts": ["low", "medium", "high"] },
          { "model": "claude-sonnet-5-5", "label": "Sonnet 5.5", "efforts": ["low", "medium", "high"] },
          { "model": "claude-opus-5-5", "label": "Opus 5.5", "efforts": ["low", "medium", "high"] }
        ]
      },
      "rewrite": { "default": { "model": "claude-sonnet-5-5", "effort": "high" }, "allowed": [] },
      "ask": { "default": { "model": "claude-opus-5-5", "effort": "medium" }, "allowed": [] }
    }
  }
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
| `ai.features.<feature>` | one entry per AI feature that is on (`key_lines`, `rewrite`, `ask`); `ai` is absent when none is | The model picker: `default` is what runs when the app sends no choice; `allowed` is every model and effort it may send ([AI model choice](#ai-model-choice)) |

In the example, `rewrite` and `ask` are shortened: each lists the same `allowed` entries as `key_lines`. A key the app
does not know is ignored; a feature the Worker does not send is off. Routes for a feature that is off
answer `404 {"error": "<feature> is not set up on this Worker."}`. Answers: `200` · `401`.

## Rows and details

`GET /prs` rows and `GET /prs/{owner}/{repo}/{n}/detail` speak the words in `worker/src/vocab.ts`, the same sets
the Pager Worker uses for threads. Examples, written by `worker/test/contract.test.ts` from the real builders and
checked on every run: [`row.json`](fixtures/row.json), [`merged-row.json`](fixtures/merged-row.json),
[`detail.json`](fixtures/detail.json), [`device-config.json`](fixtures/device-config.json),
[`alert.json`](fixtures/alert.json) (an alert's payload).

- A row's `status.list` is `review`, `reviewed` or `mine` on `GET /prs`, and `merged` on `GET /prs/merged`.
  `reviewDueAt` is on `review` rows alone, `mergedAt` on `merged` rows alone. A stored status that no longer parses is
  served as `status: null`.
- A detail's `merge` (`clean`, `behind`, `blocked`, `conflicting`, `unstable`, `unknown`) and `review` (`approved`,
  `changes_requested`, `required`, `none`) are worked out as the row's are, so the two never disagree: a conflict wins
  over a merge state that lags, and a draft is `blocked`. `mergeState` (GitHub's raw value) and `reviewDecision` stay
  for app builds that read them; new code reads `merge` and `review`. A detail stored before these fields existed lacks
  them until its PR is read again.

## Configuration

Required: `GITHUB_TOKEN` (secret), and the `DIFFS` R2 bucket, `PR_INDEX` and `AI_JOBS` Durable Objects and the
one-minute cron, as `deploy/wrangler.template.jsonc` binds them. Everything else is optional; an empty
var reads as unset.

| Name | Kind | Value |
|---|---|---|
| `GITHUB_TOKEN` | secret | The person's PAT: classic with `repo`, or fine-grained (permissions in [deploy/AGENTS.md](../deploy/AGENTS.md)) |
| `GITHUB_LOGIN` | var | Their login; unset reads it from the token |
| `GITHUB_ORGS` | var | Default filter for the app, and the owners `GET /repos` lists |
| `PR_ALERTS` | var | Visible alerts: `review_requested`, `approved`, `changes_requested`, comma-separated, or `off`. Unset: `review_requested` |
| `PUSH_RELAY_URL` | var | Jai's relay base URL |
| `PUSH_RELAY_KEY` | secret | This Worker's relay key, `rks_…` |
| `ANTHROPIC_API_KEY` | secret | Key lines, rewrites; Ask's key when `ASK_ANTHROPIC_API_KEY` is unset |
| `ASK_AGENT_ID`, `ASK_ENVIRONMENT_ID`, `ASK_VAULT_ID`, `ASK_CREDENTIAL_ID` | var | From `npm run ask-agent` |
| `ASK_GITHUB_TOKEN` | secret | A read-only PAT for Ask's agent; unset, it gets `GITHUB_TOKEN` |
| `ASK_GITHUB_APP_ID`, `ASK_GITHUB_APP_KEY` | secret | A GitHub App that mints a read-only token per question; wins over the PATs. The key is PKCS#8 (`BEGIN PRIVATE KEY`); GitHub's download is PKCS#1, so pipe it through `openssl pkcs8 -topk8 -nocrypt` |
| `AI_MODELS_ALLOWED` | var | Models the app may pick, comma-separated, from `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`. Unset: all three |
| `AI_EFFORT_MAX` | var | Highest effort offered: `low`, `medium` or `high`. Unset: `high`; nothing goes above it |
| `AI_DEFAULTS` | var | Each feature's default, `key_lines=claude-sonnet-5-5:high,rewrite=…,ask=…`, or JSON. Unset: Sonnet 5.5 at `high` for key lines and rewrites, Opus 5.5 at `medium` for Ask |
| `GUIDE_REPO`, `GUIDE_FILES` | var | The rewrite's writing guide: `owner/repo@ref` (no ref: default branch) and comma-separated paths. Unset: a built-in guide |
| `REVIEW_SLA_UTC_OFFSET_HOURS`, `REVIEW_SLA_HOURS`, `REVIEW_SLA_WEEKDAYS` | var | The review SLA week, e.g. `7`, `9-18`, `1,2,3,4,5` (Sunday 0). Unset: no row has `reviewDueAt` |
| `WEBHOOK_SECRET` | secret | Turns on `/github/webhook`; unset, it answers 404 |
| `SETUP_STATE` | secret | Turns on `/github/setup` and `/github/callback` for making a webhook App |
| `GITHUB_APP_OWNER`, `GITHUB_APP_NAME` | var | The org that owns the webhook App (unset: the person's account) and its name (unset: `<login>-pr-review`) |
| `PR_INDEX_LOCATION` | var | Durable Object location hint for the index |
| `APP_TOKEN`, `HUB_TOKEN`, `APNS_*`, `AGENT_PAGER_URL`, `AGENT_PAGER_PUSH_TOKEN`, `FEEDBACK_*`, `LINEAR_API_KEY` | | Jai's Worker; not set on a self-hosted one. With both `AGENT_PAGER_*` set, every push goes to that Worker's `POST /pr-push` instead of a device; unset, pager mode is off (`LINEAR_API_KEY` works for anyone with Linear) |

The webhook App's manifest points at the origin `/github/setup` was opened on, so it is right on any Worker. Its
credentials stay in R2 at `setup/github-app.json` until read once (`POST /github/app-credentials`, or
`wrangler r2 object get` as the guide does).

Push through the relay sends the same silent wake and alerts (below) as direct APNs. The silent wake: `push_type`
`background`, priority 5, `collapse_id` `pr-sync`, 30-minute expiry, payload `{"aps": {"content-available": 1}, "reason": "pr_sync"}`. A push
the relay refuses is recorded in `/events` with `status: null` and `reason` `relay_unauthorized`,
`relay_rate_limited`, `relay_rejected`, `relay_http_<status>` or `relay_bad_response`; a network failure is
`fetch_error: network` or `fetch_error: timeout`.

## AI model choice

Key lines, rewrites and Ask each run at a model and an effort. The Worker's vars decide what may be picked; the app
picks within that, per request, or sends nothing and gets the feature's default. Implemented in `worker/src/models.ts`.

**What can be picked.** The models this code supports (`claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`),
intersected with `AI_MODELS_ALLOWED`; efforts `low`, `medium`, `high`, up to `AI_EFFORT_MAX`. Never Fable, never
`xhigh` or `max`. `GET /device/config` lists the result under `ai.features`.

**Defaults.** `AI_DEFAULTS` sets a default per feature, as `feature=model:effort` pairs (comma, semicolon or space
between them) or JSON, `{"ask": "claude-opus-5-5:medium"}` or `{"ask": {"model": "claude-opus-5-5", "effort":
"medium"}}`. A model without an effort runs at that model's own default (Haiku and Opus `medium`, Sonnet `high`). A
feature left out keeps its built-in default, which is what each ran at before the choice existed.

**Bad config.** A var the Worker can't use doesn't stop a feature. Each bad part is dropped, logged once per isolate in
`/events` as `ai_config_error` (`{"problems": [{"variable", "value", "reason"}]}`), and the built-in value serves,
clamped to what is allowed: an allowed list with no supported model allows all three; a bad cap is `high`; a default
above the cap runs at the cap; a default on a model that isn't allowed moves to the built-in model, else the first
allowed one.

**Requests.**

- `GET /prs/{owner}/{repo}/{n}/key-lines?head=…&model=…&effort=…` and `…/rewrite?head=…&model=…&effort=…`. Both are
  optional. No `model`: the feature's default. A `model` without `effort`: the default's effort when it is the
  default model, else that model's own default, under the cap.
- `POST /prs/{owner}/{repo}/{n}/ask` takes `model` and `effort` in its JSON body, the same way.
- A model or effort outside what `/device/config` lists answers `400 {"error": {"code": "invalid_model_choice",
  "message": "effort must be one of low, medium for claude-sonnet-5-5"}}`.

**Answers.** A key lines or rewrite answer has `model` (the one that answered: a refusal fallback can differ from the
one asked for), `effort`, `tokens` and `costCents` (list price, `null` for a model with no price in the Worker). Each
model and effort has its own cached answer; the built-in default keeps the cache key from before the choice existed,
so answers made then are still served. An answer made before then has no `model`, `effort` or `costCents`.

**Ask sessions.** A Managed Agents session's model and effort are fixed when it starts; they can't change per message.
So a question at another model or effort than the PR's current session starts a new session, and the chat the app
shows is that new one; the earlier conversation is no longer shown. `GET …/ask` reports the session's `model` and
`effort` beside `costCents`.

## Quick jump

The app finds a PR from a repo's name and its number, as the Raycast `github-prs` extension does: it filters the repo
index on the phone as Jai types, and a number then opens that PR.

### `GET /repos`

Auth: a paired secret or `APP_TOKEN`. `Cache-Control: no-store`.

```json
{
  "repos": [
    {
      "nameWithOwner": "acme/web",
      "name": "web",
      "archived": false,
      "pushedAt": "2026-11-07T03:12:44Z",
      "openPrs": 4,
      "recentPrs": 12,
      "listed": 2
    }
  ],
  "owners": ["acme", "octocat"],
  "updatedAt": "2026-11-07T04:00:00.000Z",
  "truncated": false
}
```

- **Which repos.** With `GITHUB_ORGS` set, every repo of those owners (orgs or users) the token can see. Unset, every
  repo the token's user owns or sees through an org they belong to. Archived repos are included.
- `openPrs`: open PRs. `recentPrs`: the user's PRs (authored, reviewed, asked to review, commented on, mentioned in)
  updated in the last 90 days, counting at most 500. `listed`: the repo's PRs on `GET /prs` now. `pushedAt` may be
  `null`.
- **Order.** Ranked for the empty search: unarchived first, then by `listed`, `recentPrs`, `pushedAt` (newest
  first), then name. The app keeps this order among the repos its filter matches.
- **Size.** At most 3000 repos, the most recently pushed; `truncated` says some were left out. About 150 bytes a repo.
- **Freshness.** The copy in R2 (`repos/index.json`) answers at once. One older than 6 hours is answered and read again
  behind the answer. `?refresh=1` reads GitHub first, at most once every 5 minutes; sooner, it answers the copy it has,
  so `updatedAt` says which it got. `listed` is always live.
- Answers: `200` · `401` · `502 {"error": {"code": "github_unavailable", "message"}}` when there is no copy yet and
  GitHub could not be asked. An owner GitHub won't show (an unknown login, an org whose SSO the token is not
  authorized for) is left out, and the rest is served.

### `GET /prs/{owner}/{repo}/{n}/summary`

Auth: as above. A picker row for any PR the token can see, open, draft, merged or closed, read live from GitHub (one
small GraphQL query):

```json
{
  "repo": "acme/web",
  "number": 412,
  "title": "Show a retry button when checkout fails",
  "state": "merged",
  "author": "jai",
  "updatedAt": "2026-11-06T09:30:00Z",
  "url": "https://github.com/acme/web/pull/412"
}
```

- `state`: `open`, `draft`, `merged` or `closed`, as `detail` says it. `author` is `null` for a deleted account.
- Answers: `200` · `401` · `404 {"error": {"code": "not_found", "message"}}` for an unknown repo, an issue's number or
  a number past the last · `502 {"error": {"code": "github_unavailable", "message"}}`.
- Opening the PR is the usual `detail` and `diff`: a PR on neither list is read live.

### No search endpoint

The Worker has no `GET /prs/search`. The repo index is small enough to filter on the phone with no round trip per
keystroke, the phone already holds its PR list (`GET /prs`) for matching by title, and a typed number goes straight to
`summary`. GitHub's search API allows 30 queries a minute, so a search route would be slower and could run out mid-typing.

## Alerts

When a review is newly requested from the user, the Worker sends a visible push that opens the PR on a tap.
`PR_ALERTS` can add alerts for the user's own PRs: `approved` and `changes_requested`. The silent `pr_sync` wake is
unchanged and separate.

When one is sent:

- `review_requested`: a PR comes onto the review list (it was on no list, or on Recently Reviewed and the user is
  asked again) and the request is under 2 hours old, so a new Worker's first sync alerts nothing.
- `approved`, `changes_requested`: the review state of a PR on the user's list changes to it. A PR seen for the first
  time alerts nothing.
- Once per kind, PR and head commit: asked again at the same commit, the user hears nothing new. The keys are kept 30
  days.
- To every device registered on the production host, as the wake is (a Simulator's sandbox registration gets none),
  through the relay when it is set, else direct APNs; a Worker with neither sends none. Each send is in `/events` as `kind: "alert"` with `{kind, pr, status, reason}`.

The push: `push_type` `alert`, priority 10, no `collapse_id`, 24-hour expiry, and this payload (at most about 1 KB, well
under APNs' and the relay's 4096 bytes):

```json
{
  "aps": {
    "alert": { "title": "Review requested: acme/web#412", "body": "Show a retry button when checkout fails" },
    "sound": "default",
    "thread-id": "pr:acme/web#412"
  },
  "reason": "pr_alert",
  "kind": "review_requested",
  "pr": { "repo": "acme/web", "number": 412 }
}
```

- Titles: `Review requested: <repo>#<n>`, `Approved: <repo>#<n>`, `Changes requested: <repo>#<n>`, at most 120
  characters. `body` is the PR's title, at most 240. Either is cut with `…`.
- `thread-id` groups a PR's alerts in Notification Center (at most 64 characters).
- No `content-available`: the alert does not wake the app to sync.

**For the iOS agent (PRKit).** On a tap of a notification whose `reason` is `pr_alert`, open the PR named by
`pr.repo` and `pr.number` in the PRs tab, as a link to a PR opens. `kind` is for wording only; ignore a `kind` the app
does not know. PRHub must ask for alert permission (`.alert`, `.sound`) to show these; today it registers for the silent
wake only, and its `didReceiveRemoteNotification` ignores anything but `pr_sync`. Jai's Agent Pager app gets the same
payload on its own topic, and until it routes `pr_alert` a tap opens the app's default tab.

## Hosted sign-in

`HOSTED=on` makes the Worker the hosted PRHub (`https://prhub.jai-f89.workers.dev`), which everyone signs in to with
the PRHub GitHub App ([plans/github-app.md](plans/github-app.md)). Code: `worker/src/hosted.ts`, `account-core.ts`,
`account.ts`, `oauth.ts`, `token-crypto.ts`. Off, nothing here exists and the Worker is the self-hosted one above.

### Flow

The app makes a random `state` (16–256 of `A-Z a-z 0-9 . _ ~ -`) and a PKCE verifier (RFC 7636), keeps both in
memory, and opens an `ASWebAuthenticationSession` with the callback `.https(host: "<worker host>", path:
"/auth/github/done")`.

1. `GET /auth/github/start?state=<app state>&code_challenge=<S256 of the verifier>&code_challenge_method=S256`. The
   Worker keeps the app's state and challenge for 10 minutes under a state of its own, makes a second PKCE pair for
   GitHub, and answers `302` to `https://github.com/login/oauth/authorize` with `redirect_uri`
   `https://<worker>/auth/github/callback`. `400 validation_error` for a bad state or challenge, or a method other
   than `S256`.
2. GitHub redirects the browser to `GET /auth/github/callback?code&state`. The Worker takes the sign-in (once), trades
   the code with its own verifier, reads `GET /user`, keeps the tokens sealed in the person's account, and answers
   `302` to `/auth/github/done?code=<one-time code>&state=<app state>`. The session catches that URL; the app checks
   `state`.
3. `POST /auth/github/finish` with `{"code": "<one-time code>", "code_verifier": "<the app's verifier>"}`.
   `200 {"secret": "<user id>.<43 characters>", "login": "octocat", "user_id": "4242"}`, `Cache-Control: no-store`.
   The secret is the bearer for every other route, as a paired device secret is on a self-hosted Worker; keep it in
   the keychain with the Worker URL. The code works once, within 5 minutes, and only with the verifier whose S256
   went to `start`: a wrong verifier spends it.

Neither GitHub's code nor any secret reaches the app in a URL: the one-time code is useless without the verifier,
which never leaves the app.

`/auth/github/done` errors carry `error` (and `state` when the Worker knows it), and the app shows Sign in again:

| `error` | When |
|---|---|
| `access_denied` | The person cancelled on GitHub |
| `sign_in_expired` | Unknown, used or 10-minute-old sign-in; no `state` |
| `github_refused` | GitHub refused the code, or sent another error |
| `github_unavailable` | GitHub could not be asked for the tokens or the user |

`/auth/github/callback` with no `state` (GitHub's "request user authorization during installation", from an install
on github.com) answers a page that says PRHub is installed and links `prhub://`; nothing is traded.
`/auth/github/done` opened in a browser answers a page that says to return to PRHub.
`GET /.well-known/apple-app-site-association` answers `{"webcredentials": {"apps": ["<APPLE_APP_ID>"]}}`, so the
session may catch the HTTPS callback.

### Errors on every other route

`{"error": {"code", "message"}}`, `Cache-Control: no-store`:

| Status | `code` | When | The app |
|---|---|---|---|
| 401 | `unauthorized` | No bearer, or none this Worker minted (signed out on this phone, or the account deleted) | Shows Sign in with GitHub |
| 401 | `signed_out` | GitHub no longer honours the person's tokens: they revoked the App, a refresh was refused, or 6 months passed with no refresh | Shows Sign in again |
| 503 | `github_unavailable` | GitHub could not be asked for a fresh token | Retries later |
| 503 | `not_configured` | `HOSTED=on` without everything it needs | Shows the Worker is down |

`GET /device/config` answers a `signed_out` session with `200` too. On the hosted Worker it adds:

```json
{ "hosted": true, "account": { "state": "signed_in", "login": "octocat", "user_id": "4242" } }
```

`account.state` is `signed_in` or `signed_out`; a signed-out account adds `reason`: `revoked`, `refresh_expired` or
`signed_out`. Settings shows Delete Account when `hosted` is true. Key lines, Rewrite, Ask and Feedback are off on
the hosted Worker until per-person AI budgets exist (6e).

When GitHub stops honouring the tokens, the Worker sends each registered phone an alert once: title `PRHub`, body
`Sign in with GitHub again to keep your pull requests up to date.`, payload `"reason": "signed_out"`, collapse id
`prhub-sign-in`.

### `POST /auth/signout`

Auth: the session secret, signed in or not. Ends this phone's session; `204`. Other phones stay signed in. When the
last session ends, the Worker drops the person's tokens and push registrations, so it holds no token for someone with
no phone signed in.

### `DELETE /account`

Auth: the session secret, signed in or not. App Review guideline 5.1.1(v). The Worker revokes PRHub's authorization on
GitHub (`DELETE /applications/{client_id}/grant`, which also revokes every token it issued), then deletes the account,
the person's PR index and every R2 object under `users/<user id>/`. `200 {"deleted": true, "github_revoked": true}`;
`github_revoked` is false when GitHub could not take the revoke, and the data is deleted all the same. The next
request with the secret answers `401 unauthorized`.

### Tokens

- A person's tokens live in their account object, `UserAccount` named `user:<GitHub user id>`, sealed with AES-256-GCM:
  a new 12-byte IV per seal, associated data `prhub:user:<id>:access` or `:refresh`, stored as
  `v1.<key id>.<iv>.<ciphertext>` (base64url). No token goes to the phone, R2, a log or `/events`.
- `TOKEN_ENCRYPTION_KEY` is `<key id>:<base64 of 32 random bytes>`, comma-separated: the first key seals, every key
  opens. To rotate, put a new key first and keep the old one after it; each account is sealed again with the new key
  when its token is next read.
- The access token (8 hours) is refreshed 5 minutes before it expires, and when GitHub answers `401` to it. One refresh
  runs at a time per person; requests during it wait for its answer. GitHub kills the old pair as it answers.
- `bad_refresh_token`, a refresh token past its 6 months, or `github_app_authorization` `revoked` on `/github/webhook`
  signs the person out everywhere: tokens dropped, `account.state` `signed_out`, the alert above. A refresh that fails
  any other way keeps the person signed in.
- Each account's alarm runs every 10 minutes while signed in: it refreshes when due and ticks the person's PR index,
  which keeps the refresh token alive. The one-minute cron does nothing on the hosted Worker.

### Per person

- The PR index is `PrIndex` named `user:<id>`, bound to the account at sign-in. Its reads and writes use the person's
  token and login; R2 keys go under `users/<id>/`.
- Pull request webhooks are accepted and dropped until installations route them (6c); the 10-minute poll and each app
  open cover them.
- Pairing, `/github/setup`, `/github/callback`, `/github/app-credentials` and `/prs/states` answer `404`.

### Configuration

| Name | Kind | Value |
|---|---|---|
| `HOSTED` | var | `on` |
| `GITHUB_APP_CLIENT_ID` | var | The App's client ID (`Iv…`), not its App ID |
| `GITHUB_APP_CLIENT_SECRET` | secret | The App's client secret |
| `TOKEN_ENCRYPTION_KEY` | secret | The keyring above; `k1:$(openssl rand -base64 32)` to start |
| `WEBHOOK_SECRET` | secret | The App's webhook secret; unset, `/github/webhook` answers 404 |
| `APPLE_APP_ID` | var | `<team id>.<bundle id>` for the association file; unset, it answers 404 |
| `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` | var, secret | Installation tokens for Ask (6c); sign-in needs neither |
| `APNS_*` | | Push straight to APNs with Jai's key, as on his Worker |

Bindings: `DIFFS`, `PR_INDEX`, `AI_JOBS` as above, plus `USER_ACCOUNTS` (class `UserAccount`) and `SIGN_INS` (class
`SignIn`), both SQLite-backed (`new_sqlite_classes`). `HOSTED=on` without the client ID, client secret, token key or
either binding answers `503 not_configured` on every route but `/`, rather than act as a self-hosted Worker.
