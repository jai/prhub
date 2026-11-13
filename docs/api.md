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
"production" | "sandbox"}` and keeps the token lowercased, with the fingerprint of the bearer that sent it; any other
token (one the relay would refuse on every push) answers `400 {"error": {"code": "validation_error", "message"}}`.
A token registered again belongs to the device that sent it last. Unpairing (`DELETE /device/pair`) and hosted sign-out
(`POST /auth/signout`) remove that device's registrations, so no alert reaches a phone that left. Once per PR index,
on its first tick (hosted: the person's first poll), registrations kept before this rule, and those of devices no
longer paired or signed in, are removed; `/events` records `push_registrations_pruned` with `{removed: [{token, host,
reason}]}`, `token` being its first 8 hex characters and `reason` `unlinked` or `not_live`. A phone still paired
registers again at its next launch or foreground. `POST /device/event` takes an object with a `kind`
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

Auth: a paired secret. Forgets that secret and its push registrations; `204`. Other paired secrets keep working. The
next request with it answers `401`, on every isolate: a paired secret is checked with the PR index on each request.
`/events` records `unpaired` with `{push_registrations: <count removed>}`. On the hosted Worker it removes the session's
push registrations the same way.

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
| `features.ask_ai` | `CLAUDE_CODE_OAUTH_TOKEN` and `AGENT`, or `ASK_AGENT_ID`, `ASK_ENVIRONMENT_ID`, `ASK_VAULT_ID`, `ASK_CREDENTIAL_ID` and a key (`ASK_ANTHROPIC_API_KEY` or `ANTHROPIC_API_KEY`) | Shows Ask on a PR and a line |
| `features.key_lines` | `CLAUDE_CODE_OAUTH_TOKEN` and `AGENT`, or `ANTHROPIC_API_KEY` with `AI_ON_API_KEY=on` | Shows the Key lines panel and capsule |
| `features.rewrite` | `CLAUDE_CODE_OAUTH_TOKEN` and `AGENT`, or `ANTHROPIC_API_KEY` with `AI_ON_API_KEY=on` | Shows Rewrite on the description |
| `features.feedback` | `FEEDBACKKIT_URL`, `FEEDBACKKIT_APP` and `FEEDBACKKIT_TOKEN` ([Feedback](#feedback)) | Shows Feedback |
| `features.push` | the relay (`PUSH_RELAY_URL`, `PUSH_RELAY_KEY`), or direct APNs (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `APNS_BUNDLE_ID`) | Registers for push; off: syncs on open and foreground only |
| `features.webhooks` | `WEBHOOK_SECRET` | Diagnostics only: updates in seconds rather than about a minute ([Webhook reads](#webhook-reads)) |
| `login` | the GitHub login the Worker acts as; `null` if GitHub could not be asked | "Your PRs", and whose review a row shows |
| `orgs` | `GITHUB_ORGS`, comma-separated; absent when unset | The PR filter's default selection |
| `ai.features.<feature>` | one entry per AI feature that is on (`key_lines`, `rewrite`, `ask`); `ai` is absent when none is | The model picker: `default` is what runs when the app sends no choice; `allowed` is every model and effort it may send ([AI model choice](#ai-model-choice)) |
| `limits` | always: each limit in force on this Worker, by name, in the unit its name ends with; `null` is off ([Limits](#limits)) | Explains a `429 limit_reached` |

The example leaves out `limits`; [`device-config.json`](fixtures/device-config.json) and
[`device-config-hosted.json`](fixtures/device-config-hosted.json) show it for each mode. In the example, `rewrite`
and `ask` are shortened: each lists the same `allowed` entries as `key_lines`. A key the app
does not know is ignored; a feature the Worker does not send is off. Routes for a feature that is off
answer `404 {"error": "<feature> is not set up on this Worker."}`. Answers: `200` · `401`.

## Feedback

Requests for changes to the app, from the app (FeatureKit). The Worker keeps none: with `FEEDBACKKIT_URL`,
`FEEDBACKKIT_APP` and `FEEDBACKKIT_TOKEN` it forwards `/feedback` to the FeedbackKit Worker as its app and the person
it acts for. That Worker gives the person a coding chat or a public issue ([featurekit.md](featurekit.md)). Without
the three, the routes answer `404`.

App routes (app auth):

| Route | Body | Answer |
|---|---|---|
| `GET /feedback` | | `{threads: [{id, title, createdAt}], builderOnline, notice?}`, newest first |
| `POST /feedback` | `{text, build?, images?, client_ref?}` | the new chat |
| `GET /feedback/{id}` | | the chat; `404` none |
| `POST /feedback/{id}` | as above | the chat, with the message added |

- A chat: `{id, messages: [{id, role: "you" \| "agent", text, anchor: null, images}], isWorking, activity, problem,
  costCents: null, model: null, effort: null, builderOnline, thread}`. `thread` is `{host, id}`, the agent's Agents
  thread, once the runner has found it.
- `text` at most 8,000 characters; `images` up to four JPEG or PNG `{media_type, data}` of at most 1.5 MB decoded.
  Neither: `400`. A repeat `client_ref` keeps the message once.
- `isWorking` from a send until the agent's turn ends; `problem` says why the last message was not passed on.
  `builderOnline`: the runner polled in the last 90 seconds and said its Mac answers. `notice`, when sending opens a public issue, says so;
  the app shows it above a new chat.

## Rows and details

`GET /prs` rows and `GET /prs/{owner}/{repo}/{n}/detail` speak the words in `worker/src/vocab.ts`, the same sets
the Pager Worker uses for threads. Examples, written by `worker/test/contract.test.ts` from the real builders and
checked on every run: [`row.json`](fixtures/row.json), [`merged-row.json`](fixtures/merged-row.json),
[`detail.json`](fixtures/detail.json), [`device-config.json`](fixtures/device-config.json),
[`alert.json`](fixtures/alert.json) (an alert's payload).

- A row's `status.list` is `review`, `reviewed` or `mine` on `GET /prs`, and `merged` on `GET /prs/merged`.
  `requestedAt` (when review was last asked of the user himself, null for a team's request) and `reviewDueAt` are on
  `review` rows alone, `mergedAt` on `merged` rows alone. A stored status that no longer parses is
  served as `status: null`.
- `GET …/detail`, `…/diff`, `…/key-lines` and `…/rewrite` answer with `Server-Timing: github;desc="github calls";dur=<n>`,
  the GitHub calls that request made (`0` when R2 answered), so a client can measure its share of the token's hour.
- An open row's `status.draft` says whether the PR is a draft. A row stored before it was kept has none: not known
  until the PR is read again.
- A detail's `merge` (`clean`, `behind`, `blocked`, `conflicting`, `unstable`, `unknown`) and `review` (`approved`,
  `changes_requested`, `required`, `none`) are worked out as the row's are, so the two never disagree: a conflict wins
  over a merge state that lags, and a draft is `blocked`. `mergeState` (GitHub's raw value) and `reviewDecision` stay
  for app builds that read them; new code reads `merge` and `review`. A detail stored before these fields existed lacks
  them until its PR is read again.
- A detail's `checks` hold each check once: a check run again (a rerun, or a run per PR event) is its latest run, and
  the same name in two workflows is two checks. Each has `name`, `state` (`success`, `failure`, `pending`, `skipped`),
  `url`, `required` and `workflow`: the Actions workflow that ran it, or `null` for a commit status or an app's check.
  The app tells same-named checks apart by `workflow` and groups a job's matrix legs (`name (leg)`) within one.
- A detail's `tickets` are the Linear issues its title names in brackets (`[ENG-1686] [CORE-12]`, `[ENG-1, CORE-2]`),
  then those its branch name names (`eng-1686-retry`, `alex/core-12`), then those its description links as Linear
  does (a magic word such as `Fixes`, `Closes` or `Part of` before keys or issue URLs, or a `linear.app/…/issue/KEY`
  URL), each once, in a list ticket's shape: `key`, `url`, `title`, `state`, `state_type`, `state_color`, `found`. With
  `LINEAR_API_KEY` the Worker asks Linear when it reads the PR: a title's key Linear has no issue for is
  `found: false`, and a key only the branch or description names shows only once Linear has it. Without the key, or
  when Linear does not answer, `found` is null and only the title's keys show.
- A `GET /prs` row's `tickets` are every ticket its title names that Linear has (`found: true`), in the title's order;
  with none from the title, the first its branch or description names that Linear has; in the same shape. Its
  `ticket` is the first of them, for an app older than `tickets`. Empty and null without `LINEAR_API_KEY` (so always on the hosted Worker) or while Linear does not answer. The index
  keeps Linear's answer for each key and asks again after an hour; each minute's tick asks again about the held rows'
  keys that are older (50 at most), and a PR whose ticket changed is read again. Merged rows have no `ticket` or `tickets`.

- `author.name` is the name on a user's profile. `authorIsBot` is true for a GitHub App, a `[bot]` login or an account
  `BOT_AUTHORS` names. On a bot's PR, `requestedBy` is the human it was opened for, first found: a `Co-authored-by`
  trailer on its last 20 commits that is no coding agent, a "Requested by" line in its body (`@login` or a name), else
  its first assignee that is no bot. It is `{login, name, avatarUrl, source}`, `source` being `co_author`, `body` or
  `assignee`, and null on a person's own PR or when nothing is recorded.

### `POST /prs/states`

The threads hub's read of any PRs' state, with `HUB_TOKEN` as a bearer token: `{"refs": ["owner/repo#7", …]}`, 1 to
20 refs. It answers `{"states": {"owner/repo#7": {…} | null}, "unanswered": […]}`: null for a PR GitHub has not got,
and `unanswered` for one GitHub would not answer for. A state holds `title`, `state`, `checks`, `merge`, `review`,
`author`, `author_name`, `created_at`, `jai_review`, `jai_reviewed_at`, `jai_review_requested` and `review_due_at`.
`review_due_at` is when Jai's review is due by the SLA (`REVIEW_SLA_*`), ISO 8601 in UTC (`2026-11-09T03:00:00Z`), the
same time as a review row's `reviewDueAt`. It is null unless `jai_review_requested` is true, when only a team was
asked, and when the SLA is unset.

The PR index reads them, with its own cache of `.policy.yml` texts and team and org memberships, so a repeat from any
isolate is a cache hit or a free `304`. Each answer's `Server-Timing: github;desc="github calls";dur=<n>` counts the
GitHub calls it made (GraphQL and `304`s included). While the token's hour is below its reserve it answers `502`
rather than spend the rest. A `502` says why as `{"error": {"code", "message"}, "reason"}`, `code` being `github_rate_limited`,
`github_unavailable` (GitHub's own 5xx), `github_failed` (any other refusal) or `signed_out`. An answer that arrives cut off
is asked again one PR at a time.

## Configuration

Required: `GITHUB_TOKEN` (secret), and the `DIFFS` R2 bucket, `PR_INDEX` and `AI_JOBS` Durable Objects and the
one-minute cron, as `deploy/wrangler.template.jsonc` binds them. Everything else is optional; an empty
var reads as unset.

| Name | Kind | Value |
|---|---|---|
| `GITHUB_TOKEN` | secret | The person's PAT: classic with `repo`, or fine-grained (permissions in [deploy/AGENTS.md](../deploy/AGENTS.md)) |
| `GITHUB_LOGIN` | var | Their login; unset reads it from the token. The searches name it, not `@me`, so they stay this person's with `GITHUB_READ_TOKEN` set. Set it beside that token: unset, each isolate spends a `GITHUB_TOKEN` call reading it |
| `GITHUB_READ_TOKEN` | secret | A second account's PAT that makes the reads (searches, PR reads, diffs, files, `.policy.yml` and team checks), so they cost that account's rate limit. Writes, and the reads that ask about the viewer (viewed files, draft reviews, what they may resolve, the repo list), stay on `GITHUB_TOKEN`. The account needs read access to every repo the Worker lists. Ignored when `HOSTED=on` |
| `GITHUB_ORGS` | var | Default filter for the app, and the owners `GET /repos` lists |
| `PR_ALERTS` | var | Visible alerts: `review_requested`, `approved`, `changes_requested`, comma-separated, or `off`. Unset: `review_requested` |
| `PUSH_RELAY_URL` | var | Jai's relay base URL |
| `PUSH_RELAY_KEY` | secret | This Worker's relay key, `rks_…` |
| `ANTHROPIC_API_KEY` | secret | Key lines, rewrites; Ask's key when `ASK_ANTHROPIC_API_KEY` is unset |
| `AI_ON_API_KEY` | var | `on`: key lines, rewrites and Ask may run on an API key (the Worker's or a hosted person's). Unset or anything else: on the subscription alone, and an API key turns no AI on |
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | A Claude subscription's token (`claude setup-token`). With `AGENT` bound, key lines and rewrites run on it ([AI on a subscription](#ai-on-a-subscription)) and win over `ANTHROPIC_API_KEY` |
| `AGENT` | container binding | `AgentContainer`, the Agent SDK container built from `agent/Dockerfile` |
| `SUBSCRIPTION_LOGINS` | var | Hosted only: the GitHub logins, comma-separated, whose AI runs on `CLAUDE_CODE_OAUTH_TOKEN`. Unset: nobody's |
| `ASK_AGENT_ID`, `ASK_ENVIRONMENT_ID`, `ASK_VAULT_ID`, `ASK_CREDENTIAL_ID` | var | From `npm run ask-agent` |
| `ASK_GITHUB_TOKEN` | secret | A read-only PAT for Ask's agent; unset, it gets `GITHUB_READ_TOKEN`, else `GITHUB_TOKEN`. On a subscription, only it or the Ask App lets the agent clone other repos and read GitHub's API |
| `ASK_GITHUB_APP_ID`, `ASK_GITHUB_APP_KEY` | secret | A GitHub App that mints a read-only token per question; wins over the PATs. The key is PKCS#8 (`BEGIN PRIVATE KEY`); GitHub's download is PKCS#1, so pipe it through `openssl pkcs8 -topk8 -nocrypt` |
| `AI_MODELS_ALLOWED` | var | Models the app may pick, comma-separated, from `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`. Unset: all three |
| `AI_EFFORT_MAX` | var | Highest effort offered: `low`, `medium` or `high`. Unset: `high`; nothing goes above it |
| `AI_DEFAULTS` | var | Each feature's default, `key_lines=claude-sonnet-5-5:high,rewrite=…,ask=…`, or JSON. Unset: Sonnet 5.5 at `high` for key lines and rewrites, Opus 5.5 at `medium` for Ask |
| `GUIDE_REPO`, `GUIDE_FILES` | var | The rewrite's writing guide: `owner/repo@ref` (no ref: default branch) and comma-separated paths. Unset: a built-in guide |
| `REVIEW_SLA_UTC_OFFSET_HOURS`, `REVIEW_SLA_HOURS`, `REVIEW_SLA_WEEKDAYS` | var | The review SLA week, e.g. `7`, `9-18`, `1,2,3,4,5` (Sunday 0). Unset: no row has `reviewDueAt`, and the app works one out from `requestedAt` on the phone's own working week (Monday to Friday, 09:00–18:00 local) |
| `WEBHOOK_SECRET` | secret | Turns on `/github/webhook`; unset, it answers 404 |
| `SETUP_STATE` | secret | Turns on `/github/setup` and `/github/callback` for making a webhook App |
| `GITHUB_APP_OWNER`, `GITHUB_APP_NAME` | var | The org that owns the webhook App (unset: the person's account) and its name (unset: `<login>-pr-review`) |
| `PR_INDEX_LOCATION` | var | Durable Object location hint for the index |
| `BOT_AUTHORS` | var | Accounts GitHub calls users that open PRs for someone else, comma-separated logins. Their PRs say they are a bot's (`authorIsBot`) and name who asked (`requestedBy`). Unset: only GitHub Apps and `[bot]` logins |
| `APP_TOKEN`, `HUB_TOKEN`, `APNS_*`, `AGENT_PAGER_URL`, `AGENT_PAGER_PUSH_TOKEN`, `LINEAR_API_KEY` | | Jai's Worker; not set on a self-hosted one. With both `AGENT_PAGER_*` set, every push goes to that Worker's `POST /pr-push` instead of a device; unset, pager mode is off (`LINEAR_API_KEY` works for anyone with Linear) |

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

A failed key lines or rewrite answer is `{"error": "…"}`, with `"moved": true` when the PR had moved past the asked
commit: the app then reads the PR at its newest commit and asks again, once. The app reads a passing failure (no
network, a timeout, a `5xx` or `429`) again rather than showing it.

**Ask sessions.** A Managed Agents session's model and effort are fixed when it starts; they can't change per message.
So a question at another model or effort than the PR's current session starts a new session, and the chat the app
shows is that new one; the earlier conversation is no longer shown. `GET …/ask` reports the session's `model` and
`effort` beside `costCents` (`null` on a subscription, which is billed by plan).

**Asking.** `POST …/ask` stores the question and answers `202` with the chat as `GET …/ask` last read it, the question
at its end and `isWorking` true. It never waits on GitHub or the agent: the person's ask queue (an `AiJobs` object of
its own) mints the repo token, starts or wakes the session and sends the question from its alarm, one question at a
time, in order. Until the agent has a question, `GET …/ask` shows it at the chat's end, working. A question the agent
could not get stays there with `isWorking` false and the reason in `problem` (a refusal in its own words, else "The AI
couldn't be reached. Try again."); one still waiting after 2 minutes says "The question didn't reach the AI. Try
again." The next question to that PR replaces a failed one. A copy with the same `client_ref` answers the chat again
and stores nothing.

## AI on a subscription

With `CLAUDE_CODE_OAUTH_TOKEN` set and `AGENT` bound, key lines, rewrites and Ask run in a container with the Claude
Agent SDK (`agent/`), signed in to a Claude subscription, instead of on the Messages API and Managed Agents. The answer, the model and effort
choice, and the stored shape are the same. A key lines or rewrite answer's `costCents` is what the run would have
cost on the API; Ask's chat has `costCents` `null`, so the app shows no cost, and the API cost goes to `ai_run` alone.

- Key lines are made ahead for each new head of every open PR on the person's lists: the review list five a pass;
  reviewed and mine one a pass, and only while the GitHub token's hour is above its reserve, since each run reads every
  changed file. An alert waits for those on the review list
  ([Alerts](#alerts)). On an API key they are made only when the app asks.
- Each run, on either path, logs one `ai_run` line: `feature`, `repo`, `number`, `auth` (`subscription` or
  `api_key`), `user_id`, `model`, `effort`, `input_tokens`, `output_tokens`, `cost_cents`.
- Ask: each question is one Agent SDK turn on a checkout of the PR at its head, fetched with the same token as on
  Managed Agents, with the PR's diff beside it as `.prhub-pr.diff` (the first 400,000 characters). The system prompt
  names the repo, the PR's number, title, author, head and base branches, state and link, and holds its description
  (the first 6,000 characters) fenced in `<pr-description>` as data the agent must not take instructions from. The
  chat is kept in R2 at `ask/<repo>/<n>.json` and the session's transcript at `ask-sessions/<repo>/<n>.json`, so the
  next question resumes it in any container. A question at another model or effort starts a new chat.
- Ask's agent reads, nothing else. It has no shell and no write or edit tool. Its tools, which the container runs
  itself (`agent/read-tools.mjs`), are:
  - Read, Grep and Glob, inside the PR's checkout and the person's cloned repos (`<scope>/.clones/<owner>/<name>`),
    symlinks followed.
  - `git`: one subcommand of `log`, `show`, `rev-list`, `shortlog`, `diff`, `grep`, `blame`, `describe`,
    `rev-parse`, `merge-base`, `name-rev`, `ls-files`, `ls-tree`, `cat-file` and `for-each-ref`, each with its own
    options (`GIT_READS` in `agent/read-tools.mjs`). An option not listed, and any abbreviation, is refused. An option
    whose value git takes as optional (`--pretty`, `--abbrev`, `-U`) takes it attached (`--abbrev=8`, `-U5`) or not at
    all, never from the next argument; one whose value git requires may take the next argument, if that does not start
    with `-` and is no path out of the repo. Whatever the lists say, an argument starting with `--output`, `-o`,
    `--ext-diff`, `--textconv`, `--open-files-in-pager`, `-O`, `--exec`, `--upload-pack`, `--config`, `-c`,
    `--git-dir`, `--work-tree` or `--namespace` is refused. Git runs without a shell, with an empty stdin, no global
    or system config, and `-c` overrides of the repo's own (`core.fsmonitor=false`, `core.hooksPath=/dev/null`,
    `core.pager=cat`, `core.editor=false`, `core.sshCommand=false`, https the only protocol); `log`, `show` and `diff`
    get `--no-ext-diff --no-textconv`, `blame` and `grep` `--no-textconv`. A checkout's or clone's `.git/config` is
    made read only once set up. Git runs in the repo's real path inside the person's directory, and a path argument
    that is absolute, starts with `~`, climbs with `..`, or resolves out of the repo through a symlink is refused.
  - The container's code, `/app`, is root's and read only to the agent's user; checkouts and clones live under its
    home.
  - `clone_repo` (`owner/name`, optional branch, tag or commit): a blobless clone with branches and tags into the
    person's clones; again, it updates.
  - `github_api`: one `GET` of a path on `https://api.github.com`, redirects not followed. No other method is offered.

  A PreToolUse hook checks each call against these rules and denies any other tool; each tool checks again. The token
  rides each git command's header and the API request, never the agent's view or disk. It and
  `CLAUDE_CODE_OAUTH_TOKEN` are taken out of every tool's output and of the answer.
- Hosted, the container is told the repos this question's token names, and only those clones can be read, gitted or
  made: a clone made while the person could see a repo is shut once they can't.
- Each person's questions run in a container of their own (`ask:<user id>`; `ask:self` on a Worker of one's own), so
  no person's agent shares a disk with another's checkouts. Key lines and rewrites share one (`ai`). Each sleeps after
  two idle minutes, and the hosted Worker allows eight at once.
- `clone_repo` and `github_api` exist only when the token is read only by how it was made: hosted, the PRHub App's
  installation token for the PR's installation, naming every repo of it the person can see (up to 500). The Worker
  reads that list with the person's own token, `GET /user/installations/{id}/repositories`, keeps it under their
  prefix at `ask-reach/<installation>.json` for ten minutes, and mints the token for those repos alone; the person's
  token never reaches the container. A repo outside it, one they can't see or one the App isn't on, answers the agent
  "You can't access …", and a PR they can't see, or in a repo the App isn't on, gets no token. On a Worker with the Ask App
  (`ASK_GITHUB_APP_ID`), its installation token across every repo it is installed on; else `ASK_GITHUB_TOKEN`. Each
  installation token asks `contents`, `pull_requests`, `issues`, `checks`, `actions` and `statuses` read and lasts an
  hour. With `GITHUB_READ_TOKEN` or `GITHUB_TOKEN`, which may write, the agent keeps to `git` on the checkout, and
  its prompt says so.
- The container runs in the US (`constraints.regions`): nearest the request it can land where Anthropic's API refuses it.
- The container sleeps after two idle minutes. The first run after that waits for it to start, about 20 seconds.
- A container that is not ready, whose run was stopped, or that dropped the connection (a deploy replaces it) is
  tried up to four times, five seconds apart.
- A failed answer, on either path, is served for ten minutes; the next ask after that makes it again, so a run that
  failed for want of credit or capacity heals without **Try again**.

## Tracing an Ask

Each Ask turn has one id, the question's own (its `client_ref`, else one the Worker makes). Every stage writes one
`ask_event` log line with `turn`, `stage`, `pr` and `user_id`, and the fields of that stage:

| `stage` | When | Fields |
|---|---|---|
| `queued` / `received` | `POST …/ask` stored the question, or found it already there (`repeat`) | |
| `handed_over` / `resumed` | The queue gave it to the agent; `resumed` when a turn a deploy cut short runs again | `model`, `effort` |
| `grant` | GitHub's read-only token for the turn is minted | `ms`, `read_only`, `repos` |
| `container` | The Agent SDK container answered | `ms`, `subtype`, `tools` |
| `answered` | The answer is in the chat | `ms`, `model`, `cost_cents` |
| `failed` | The turn ended without an answer | `ms`, `side`, `reason`, `status` |

`side` is where it failed: `app`, `worker`, `github`, `container` or `model`. The chat's problem for a failed turn is
`<side>[ <status>]: <reason> · turn <first 8 characters of the id>`, for example `GitHub 403: GitHub's rate limit for
your account is used up, resets 02:59 UTC · turn 3f2a9c1e`. A GitHub token that fails for a passing reason (no answer,
a dropped connection) is asked for once more before the turn fails. `scripts/ask-trace.sh <id> [worker]` prints a
turn's lines from Workers Logs.

## Reviewed key lines

The key lines the person has checked off, kept in their index so each of their devices shows the same ticks. They are
kept by head: a new commit starts the review again. A key line is named by its id, `path:side:line` (`LEFT` or `RIGHT`),
the same at every context, so a tick holds when the context changes. The route needs no AI key.

- `GET /prs/{owner}/{repo}/{n}/key-lines-reviewed?head=…` answers `{"head": "…", "reviewed": ["src/a.ts:RIGHT:12"]}`,
  the ids sorted, with `Cache-Control: no-store`.
- `POST /prs/{owner}/{repo}/{n}/key-lines-reviewed` with `{"head": "…", "line": "src/a.ts:RIGHT:12", "reviewed": true}`
  checks one off, or `false` back on, and answers as `GET` does. Sending it twice is the same as once.
- `400 validation_error` for a head that is not a 40-character commit or a line id that is empty or over 1,100
  characters; `400 too_many` past 500 ticks at one head.

Ticks at a head no held PR has (an older commit, a PR off the list) go after 30 days; a held PR's ticks at its head stay.
Losing a repo's access takes its ticks at once, and `DELETE /account` takes them with the rest of the index. An older
Worker answers `404`: the app then keeps ticks on the device.

## Limits

Every limit is a `LIMIT_*` var: a whole number in the limit's unit, or `off` where the table allows it. Unset or
empty, a limit takes its default for the Worker's mode. A self-hosted Worker's defaults keep its behaviour from before
limits existed: no per-person counts, no retention sweep. Implemented in `worker/src/limits.ts`; `GET /device/config`
shows each limit in force under `limits`.

A var the Worker cannot use does not stop anything. The default serves, and the problem is logged once per isolate in
`/events` as `limits_config_error` (`{"problems": [{"variable", "value", "reason"}]}`).

**Per IP**, counted in an `IpLimit` object per IP hash (hosted) or the index (self-hosted). `off` allowed.

| Limit | Var | Hosted | Self-hosted | Counts |
|---|---|---|---|---|
| `sign_in_starts_per_ip_per_minute` | `LIMIT_SIGN_IN_STARTS_PER_IP_PER_MINUTE` | 10 | n/a | `GET /auth/github/start` |
| `sign_in_finishes_per_ip_per_minute` | `LIMIT_SIGN_IN_FINISHES_PER_IP_PER_MINUTE` | 10 | n/a | `POST /auth/github/finish` |
| `pairing_attempts_per_ip_per_hour` | `LIMIT_PAIRING_ATTEMPTS_PER_IP_PER_HOUR` | n/a | 30 | `POST /device/pair` |

**Per person**, counted in the person's own `PrIndex`. `off` allowed.

| Limit | Var | Hosted | Self-hosted | Counts |
|---|---|---|---|---|
| `writes_per_minute` | `LIMIT_WRITES_PER_MINUTE` | 20 | off | `POST …/write`: reviews, comments, merges, description edits |
| `writes_per_hour` | `LIMIT_WRITES_PER_HOUR` | 200 | off | The same |
| `ask_questions_per_hour` | `LIMIT_ASK_QUESTIONS_PER_HOUR` | 30 | off | `POST …/ask` |
| `ask_questions_per_day` | `LIMIT_ASK_QUESTIONS_PER_DAY` | 150 | off | The same |
| `ai_jobs_per_hour` | `LIMIT_AI_JOBS_PER_HOUR` | 60 | off | A key lines or rewrite request that starts a job; a stored answer counts nothing |

**Sizes and intervals.**

| Limit | Var | Hosted | Self-hosted | What it sets |
|---|---|---|---|---|
| `ask_session_budget_cents` | `LIMIT_ASK_SESSION_BUDGET_CENTS` | 200 | 200 | The list-price spend at which Anthropic stops one PR's Ask session |
| `github_reserve_percent` | `LIMIT_GITHUB_RESERVE_PERCENT` | 10 | 10 | The share of a token's hour that background reads leave alone (0 to 90) |
| `github_reserve_minimum` | `LIMIT_GITHUB_RESERVE_MINIMUM` | 100 | 100 | The least of a token's requests that background reads leave alone |
| `indexed_pull_requests_max` | `LIMIT_INDEXED_PULL_REQUESTS_MAX` | 500 | off | PRs one index holds; a new PR past it waits (`limit_reached` in `/events`). `off` allowed |
| `indexed_repos_max` | `LIMIT_INDEXED_REPOS_MAX` | 3000 | 3000 | Repos in `GET /repos` |
| `closed_pull_request_retention_days` | `LIMIT_CLOSED_PULL_REQUEST_RETENTION_DAYS` | 30 | off | How long R2 keeps the diffs, details, AI answers and Ask record of a PR no longer on the list. `off` allowed |
| `poll_interval_minutes` | `LIMIT_POLL_INTERVAL_MINUTES` | 10 | n/a | Each person's background poll and token refresh |
| `installation_sync_hours` | `LIMIT_INSTALLATION_SYNC_HOURS` | 6 | n/a | How often the poll reads the person's installations again |
| `installation_sync_on_open_minutes` | `LIMIT_INSTALLATION_SYNC_ON_OPEN_MINUTES` | 10 | n/a | The least time between installation reads on app open |
| `installation_reads_now_per_minute` | `LIMIT_INSTALLATION_READS_NOW_PER_MINUTE` | 6 | n/a | Installation reads a config waits for: an empty list, or `?fresh=1` ([Hosted sign-in](#hosted-sign-in)). `off` allowed |
| `session_lifetime_days` | `LIMIT_SESSION_LIFETIME_DAYS` | 180 | n/a | A phone's session; after it, the phone signs in again |
| `sessions_max` | `LIMIT_SESSIONS_MAX` | 20 | n/a | Signed-in phones per person; the oldest session goes first |
| `sign_in_minutes` | `LIMIT_SIGN_IN_MINUTES` | 10 | n/a | From `/auth/github/start` to GitHub's callback |
| `sign_in_code_minutes` | `LIMIT_SIGN_IN_CODE_MINUTES` | 5 | n/a | The one-time code `/auth/github/finish` takes |

**Past a limit**, the route answers `429` with `Retry-After` and `Cache-Control: no-store`:

```json
{ "error": { "code": "limit_reached", "message": "writes_per_minute reached; try again in 41 s",
  "limit": "writes_per_minute", "retry_after": 41 } }
```

`retry_after` is in seconds: when the oldest counted request leaves the window. A refused request counts toward no
limit. A write or question sent again with the same `client_ref` (the outbox's retry) is the request already counted:
it never counts twice, and passes a limit it passed the first time. A refused write keeps no receipt, so the outbox can
send it again after `retry_after`. Polling a key lines or rewrite answer counts the job once.

**Retention.** Once a day, each index's tick deletes the R2 objects of each PR no longer on its list whose newest object
is older than `closed_pull_request_retention_days` (`retention_swept` or `retention_failed` in `/events`). A PR on the
list keeps everything.

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
- Only once the PR's detail and diff, and its key lines when this Worker makes them (on the subscription, and the PR on
  the review list), are stored at the head the alert is about, so the phone reads them from R2 and never waits on
  GitHub. An alert waits 30 seconds at most, then goes anyway; one whose PR's head moved on goes at once, and one whose
  PR left every list is not sent (`alert_dropped`). Each held alert is in `/events` as `push_delayed` with `{kind, pr,
  ms, reason}`, `reason` being `ready`, `moved` or `timed_out`.
- To every device registered on the production host, as the wake is (a Simulator's sandbox registration gets none),
  through the relay when it is set, else direct APNs; a Worker with neither sends none. Each send is in `/events` as `kind: "alert"` with `{kind, pr, title, held_ms, status, reason}`.

The push: `push_type` `alert`, priority 10, no `collapse_id`, 24-hour expiry, and this payload (at most about 1 KB, well
under APNs' and the relay's 4096 bytes):

```json
{
  "aps": {
    "alert": { "title": "Review requested: acme/web#412", "body": "Show a retry button when checkout fails" },
    "sound": "default",
    "thread-id": "pr:acme/web#412",
    "mutable-content": 1
  },
  "reason": "pr_alert",
  "kind": "review_requested",
  "pr": { "repo": "acme/web", "number": 412 },
  "row": { "repo": "acme/web", "number": 412, "title": "…", "head": "…", "revision": "…", "diff": "ready", "detail": "…", "status": {}, "keyLines": 100 }
}
```

- Titles: `Review requested: <repo>#<n>`, `Approved: <repo>#<n>`, `Changes requested: <repo>#<n>`, at most 120
  characters. `body` is the PR's title, at most 240. Either is cut with `…`.
- `thread-id` groups a PR's alerts in Notification Center (at most 64 characters).
- `row` is the PR's row exactly as `GET /prs` lists it when the alert goes ([docs/fixtures/alert.json](fixtures/alert.json)).
  It is left out when it would take the payload past 4000 bytes.
- `mutable-content: 1`: PRHub's Notification Service Extension fetches the row's stored detail and diff (`?version=`,
  `?revision=`) into the app's mirror before the alert shows, so a tap opens the PR from the phone. It gives up within
  iOS's time for an extension and shows the alert either way.
- No `content-available`: the alert does not wake the app to sync.

**For the iOS agent (PRKit).** On a tap of a notification whose `reason` is `pr_alert`, open the PR named by
`pr.repo` and `pr.number` with `PRKitController.open(alert:row:)`, `row` being `PRPush.row(in:)`. `kind` is for
wording only; ignore a `kind` the app does not know. A Notification Service Extension that links PRKitCore fetches the
row first with `PRPushPrefetch` into `PRMirrorLocation.directory(appGroup:)`, the folder the host also names as
`PRKitHost.mirrorDirectory`; the tap then shows the PR from the phone. Without it, the tap reads the row's stored copy,
detail and diff side by side, and only a PR on no list is read live. Jai's Agent Pager app gets the same payload on its
own topic.

## Library

Another Worker can serve one person's PRs on that person's token, with this code inside it (`worker/src/lib.ts`):

- `serveOwner(request, env, context, isHostAuthorized)`: every route of a one-person Worker, with the paths as here.
  The host strips its own prefix first. `isHostAuthorized` says the host has checked the caller with its own
  credentials; `/github/webhook` (signature), `/prs/states` and `/feedback/runner/*` (`HUB_TOKEN`) still check theirs,
  and `APP_TOKEN` is still accepted.
- `tickOwnerIndex(env, time)`: what the one-minute cron does.
- `PrIndex` and `AiJobs`: the host binds them as `PR_INDEX` and `AI_JOBS`, with R2 as `DIFFS`, and names its other
  vars as in "Configuration". It exports a subclass of `PrIndex` that overrides `deliverByHost(message)`: each push
  (`PushMessage`) goes to the host, which answers APNs' status and reason (`PushOutcome`). The index then never
  pushes itself.

### `GET /export` and `POST /import`

For moving one person's index to another Worker, on a one-person Worker only, with the usual bearer. `GET /export`
answers what GitHub can't give back: `{reviewedKeyLines: [{pr, head, line, at}], reviewedPullRequests: [{id, repo,
number}], asks: [{id, pr, ask, at, error}], askChats: [{pr, chat, at}]}`. `reviewedPullRequests` are the PRs held on
Recently Reviewed. `POST /import` takes that body, adds the rows the index lacks (a row it has stays as it is), reads
each carried PR from GitHub again, and answers `{reviewedKeyLines, reviewedPullRequests, asks, askChats}`: how many of
each the index now holds. Any other body is
`400 validation_error`.

## Hosted sign-in

`HOSTED=on` makes the Worker the hosted PRHub (`https://prhub.jai-f89.workers.dev`), which everyone signs in to with
the PRHub GitHub App ([plans/github-app.md](plans/github-app.md)). Code: `worker/src/hosted.ts`, `account-core.ts`,
`account.ts`, `oauth.ts`, `token-crypto.ts`, `installation-core.ts`, `installations.ts`, `rate-limit.ts`. Off, nothing
here exists and the Worker is the self-hosted one above. Deploying it: [hosted-deploy.md](hosted-deploy.md).

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
| 429 | `limit_reached` | A [limit](#limits): sign-in from one IP, or one person's writes, questions or AI jobs. `limit` names it; `retry_after` says when to try again | Waits `retry_after` |

`GET /device/config` answers a `signed_out` session with `200` too. On the hosted Worker it adds:

```json
{ "hosted": true, "account": { "state": "signed_in", "login": "octocat", "user_id": "4242", "anthropic_key": false } }
```

`account.state` is `signed_in` or `signed_out`; a signed-out account adds `reason`: `revoked`, `refresh_expired` or
`signed_out`. `account.anthropic_key` says whether the person gave their own Anthropic key; the key itself is never
answered.

A signed-in session's config also names the installations of the PRHub App that the person's own token reaches
(`GET /user/installations`), their own account first, then the rest by name:

```json
{
  "installations": [
    { "account": "octocat", "account_type": "User", "avatar_url": "https://avatars.githubusercontent.com/u/1?v=4",
      "installation_id": 1, "repository_selection": "all", "suspended": false },
    { "account": "acme", "account_type": "Organization", "avatar_url": "https://avatars.githubusercontent.com/u/2?v=4",
      "installation_id": 2, "repository_selection": "selected", "repo_count": 2, "suspended": false }
  ]
}
```

| Field | Means |
|---|---|
| `account`, `account_type` | The user or org the App is installed on: `User` or `Organization` |
| `avatar_url` | Its GitHub picture |
| `installation_id` | GitHub's id: the installation's settings are `https://github.com/settings/installations/<id>` for a user, `https://github.com/organizations/<account>/settings/installations/<id>` for an org |
| `repository_selection` | `all`: every repo of the account; `selected`: the repos picked on GitHub |
| `repo_count` | With `selected` only: how many of the picked repos the person's own token sees. Absent while suspended |
| `suspended` | The App is suspended there: it routes nothing until it is unsuspended |

The list is what the last [installation sync](#webhook-routing) read: at sign-in, on app open every
`installation_sync_on_open_minutes`, every `installation_sync_hours`, and at once for the person who installed,
uninstalled, suspended or changed the repos of an installation (its webhook). The config reads GitHub before it
answers, and answers with that read, when a list it held could be wrong: the first config of a new session, a list
that is empty or not read yet, and `GET /device/config?fresh=1`, which the app sends when it comes back from GitHub's
install or installation pages. Those reads are at most `installation_reads_now_per_minute`, spaced evenly, except a
new session's first; one GitHub has not finished within 8 seconds goes on after the answer, which has the list as it
was. `installations` is absent before the first sync and for a signed-out session. Orgs the person belongs to that have no installation are not listed: a GitHub
App's user token lists only orgs where the App is installed (`GET /user/orgs`), and listing all of them would need a
`read:org` OAuth scope the App does not ask for.

Settings shows Delete Account when `hosted` is true. On the hosted Worker AI runs only on the person's own
key: `features.key_lines` and `features.rewrite` are on once they gave it, and `features.ask_ai` once Ask's resources
were made in their org ([`PUT /account/anthropic-key`](#put-accountanthropic-key)). Feedback is always off.

When GitHub stops honouring the tokens, the Worker sends each registered phone an alert once: title `PRHub`, body
`Sign in with GitHub again to keep your pull requests up to date.`, payload `"reason": "signed_out"`, collapse id
`prhub-sign-in`.

### `POST /auth/signout`

Auth: the session secret, signed in or not. Ends this phone's session and removes its push registrations
(`device_signed_out` in `/events`, with `{push_registrations: <count removed>}`); `204`. Other phones stay signed in.
When the last session ends, the Worker drops the person's tokens and every push registration, so it holds no token for
someone with no phone signed in.

### `PUT /account/anthropic-key`

Auth: a signed-in session. Body `{"key": "<Anthropic API key>"}`. The Worker asks Anthropic whether the key works (one
`GET /v1/models`), then, when it holds the App's private key, makes Ask's agent, environment and vault in the key's org
(what `npm run ask-agent` makes for a self-hosted Worker). It keeps the key sealed like the tokens (associated data
`prhub:user:<id>:anthropic`) and never answers it back. Key lines, rewrites and Ask then run on it, as the person:
their GitHub token, their R2 prefix, their `AiJobs`, and AI answers kept under `users/<id>/ai/…`.

`200 {"anthropic_key": true, "ask_ai": true}`; `ask_ai` is false when the Worker cannot mint installation tokens or
Ask's resources could not be made (key lines and rewrites still work). `400 validation_error` for a key that is not
20–300 URL-safe characters, `422 anthropic_key_invalid` when Anthropic refuses it, `503 anthropic_unavailable` when it
could not be asked, `401` as on every route. Giving a key again replaces the key and makes Ask's resources again.

`DELETE /account/anthropic-key`: `204`; AI is off for the person again. Signing out of the last phone, being signed out
by GitHub, and Delete Account drop the key too.

### `DELETE /account`

Auth: the session secret, signed in or not. App Review guideline 5.1.1(v). The Worker revokes PRHub's authorization on
GitHub (`DELETE /applications/{client_id}/grant`, which also revokes every token it issued), then deletes the account,
the person's PR index and every R2 object under `users/<user id>/`, and takes them out of every installation, so no
later webhook reaches them. `200 {"deleted": true, "github_revoked": true}`;
`github_revoked` is false when GitHub could not take the revoke, and the data is deleted all the same. The next
request with the secret answers `401 unauthorized`.

### Tokens

- A person's tokens live in their account object, `UserAccount` named `user:<GitHub user id>`, sealed with AES-256-GCM:
  a new 12-byte IV per seal, associated data `prhub:user:<id>:access` or `:refresh`, stored as
  `v1.<key id>.<iv>.<ciphertext>` (base64url). No token goes to the phone, R2, a log or `/events`.
- `TOKEN_ENCRYPTION_KEY` is `<key id>:<base64 of 32 random bytes>`, comma-separated: the first key seals, every key
  opens. To rotate, put a new key first and keep the old one after it. Each signed-in account's poll seals its
  tokens and Anthropic key again with the new key, and records `token_keys` in the person's `/events` (`current`,
  `resealed`, and `stale`: values still on a key that is gone). The runbook is in
  [hosted-deploy.md](hosted-deploy.md#rotating-the-token-key).
- The access token (8 hours) is refreshed 5 minutes before it expires, and when GitHub answers `401` to it. One refresh
  runs at a time per person; requests during it wait for its answer. GitHub kills the old pair as it answers.
- `bad_refresh_token`, a refresh token past its 6 months, or `github_app_authorization` `revoked` on `/github/webhook`
  signs the person out everywhere: tokens dropped, `account.state` `signed_out`, the alert above. A refresh that fails
  any other way keeps the person signed in.
- Each account's alarm runs every `poll_interval_minutes` (10) while signed in: it refreshes when due and ticks the
  person's PR index, which keeps the refresh token alive. The one-minute cron does nothing on the hosted Worker.

### Per person

- The PR index is `PrIndex` named `user:<id>`, bound to the account at sign-in, and `AiJobs` is named the same. Their
  reads and writes use the person's token and login; R2 keys go under `users/<id>/` (rows' diffs and details, the repo
  index, AI answers, Ask's session record). Nothing one person holds is named so another's request can reach it.
- Pairing, `/github/setup`, `/github/callback`, `/github/app-credentials` and `/prs/states` answer `404`.

### Webhook routing

Every delivery is signed with the App's webhook secret (`WEBHOOK_SECRET`); a bad signature answers `401` and touches
nothing. Each installation has an `Installation` object named `installation:<id>` that knows its members and which of
its repos each one can see. Who sees what comes only from each person's own token, never an installation token:

- **Joining.** At sign-in, on app open (`GET /device/config`) when the last read is `installation_sync_on_open_minutes`
  old or the list needs reading before the answer (a new session, an empty list, `?fresh=1`), and every `installation_sync_hours` from the account's alarm, the Worker reads `GET /user/installations` and
  `GET /user/installations/{id}/repositories` with the person's token. They join each installation listed, with exactly the repos listed, and leave the ones no
  longer listed. A partial answer changes nothing.
- **`installation`.** `created`, `new_permissions_accepted` and `unsuspend` record the repos it names. `suspend`
  routes nothing until `unsuspend`, and drops each member's rows of the installation's repos at once; after
  `unsuspend` the poll reads them again. `deleted` drops the same rows and forgets the installation. Every action
  then reads the installations of the person who acted, if they have signed in. A sync reads no repos of a suspended
  installation and leaves its members as they were.
- **`installation_repositories`.** `added` records the repos; `removed` forgets the repos, so nobody is routed to
  them, and drops each member's rows of them at once. Both then read the actor's installations again.
- **`pull_request`, `pull_request_review`, `pull_request_review_comment`, `pull_request_review_thread`,
  `issue_comment` (on a PR).** Marked in the index of each member whose list has the repo, `involved` when they wrote
  the PR or are asked to review it. A PR an index does not hold, with the person not involved, costs nothing.
- **`check_suite`, `status`.** Only the checks of the PRs each such member's index holds at that head are read again
  ([Webhook reads](#webhook-reads)).
- **In doubt.** A member is in doubt about a repo the installation gained, or a delivery named first, after their list
  was read. The delivery waits in the installation while their own token is asked (`GET /repos/{repo}`): yes delivers
  it and is kept; no drops it and is kept until the repo is added again; no answer (GitHub away, or rate limited) is
  asked twice more, then the delivery is left to their poll. Signed out counts as no.

The index reads GitHub only with the person's token, so even a mark that reached the wrong index could show nothing
their token cannot read.

### Webhook reads

A delivery only marks a PR; the index's alarm reads it (`marks.ts`). This applies to the hosted Worker and to a
self-hosted one with `WEBHOOK_SECRET` alike. A busy org sends many deliveries for the same PR or head (each check
suite and status of a CI run, a bot's run of comments), so each read covers a burst:

- **After quiet**, the first delivery is read 3 seconds later.
- **PR events and comments** read the whole PR (detail, review, policy, tickets) at most once every 15 seconds. A
  comment in the middle of a burst shows within 15 seconds.
- **`check_suite` and `status`** read only the PR's checks, merge state and PolicyBot's status: one GraphQL query for
  up to 25 PRs, with no REST call. They read at most once every 30 seconds per PR, so a check that finishes in the
  middle of a CI run shows within 30 seconds. A PR is read in full instead (within its 15-second window) when its head
  or `updatedAt` moved, or when its `.policy.yml` people decision is more than 10 minutes old or missing. That
  decision outranks PolicyBot's live status. A PR GitHub refuses in that query (SAML, say) leaves the others' reads
  alone. Merged rows are not read for checks.
- **The one-minute poll** marks a PR whose search listing differs only in its checks rollup for a checks-only read too.
- **More deliveries never delay a read that is waiting.** A delivery that arrives while its PR is being read is read
  again when the window ends; your own write that arrives then is read at once.
- **Your own write** (a review or a merge from the app) is read 3 seconds later, whatever came before it.

`.policy.yml` texts (10 minutes) and team and org memberships (an hour) are kept in the person's index storage with
their ETags. Past those times they are asked again with `If-None-Match`, and GitHub's `304` does not count against
the person's hour.

### Rate limits

- **GitHub, per token.** Every GitHub call reads `x-ratelimit-remaining`, `-limit`, `-reset` and `retry-after`. When
  under the reserve (`github_reserve_percent` of the hour, at least `github_reserve_minimum`; a tenth and 100 by
  default) is left, the person's poll and webhook reads wait for the reset; their own
  requests still go. When none is left, or GitHub sends `retry-after` or `429` (a secondary limit; a minute when it
  gives no time), every call for that token answers `429` with `retry-after` until then, without reaching GitHub.
  Each backoff is in `/events` once as `rate_limited` (`kind` `low`, `primary` or `secondary`, `until`, `remaining`,
  `limit`). Each hosted poll records its cost as `polled` (`calls`, `remaining`, `limit`). The same applies to a
  self-hosted Worker's token. With `GITHUB_READ_TOKEN` set, its calls are held apart from `GITHUB_TOKEN`'s, so a read
  token that runs out stops the reads, not the writes; a background run waits when either runs low.
- **Sign-in, per IP.** `/auth/github/start` and `/auth/github/finish` answer `429 limit_reached` past
  `sign_in_starts_per_ip_per_minute` and `sign_in_finishes_per_ip_per_minute` ([Limits](#limits)). Each IP is
  counted by its SHA-256 in an `IpLimit` object, which deletes itself when its last count expires.

### Configuration

| Name | Kind | Value |
|---|---|---|
| `HOSTED` | var | `on` |
| `GITHUB_APP_CLIENT_ID` | var | The App's client ID (`Iv…`), not its App ID |
| `GITHUB_APP_CLIENT_SECRET` | secret | The App's client secret |
| `TOKEN_ENCRYPTION_KEY` | secret | The keyring above; `k1:$(openssl rand -base64 32)` to start |
| `WEBHOOK_SECRET` | secret | The App's webhook secret; unset, `/github/webhook` answers 404 |
| `APPLE_APP_ID` | var | `<team id>.<bundle id>` for the association file; unset, it answers 404 |
| `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` | var, secret | Installation tokens for Ask: read only, one repo, minted only after the person's own token read the PR. Unset: Ask stays off for everyone. PKCS#8 |
| `AI_DEFAULTS` and the other AI vars | var | As above; they apply to each person's own key |
| `LIMIT_*` | var | [Limits](#limits), at the hosted defaults when unset |
| `APNS_*` | | Push straight to APNs with Jai's key, as on his Worker |

Bindings: `DIFFS`, `PR_INDEX`, `AI_JOBS` as above, plus `USER_ACCOUNTS` (class `UserAccount`), `SIGN_INS` (class
`SignIn`), `INSTALLATIONS` (class `Installation`) and `IP_LIMITS` (class `IpLimit`), all SQLite-backed
(`new_sqlite_classes`). `HOSTED=on` without the client ID, client secret, token key or any of the four bindings answers
`503 not_configured` on every route but `/`, rather than act as a self-hosted Worker. The
template is `deploy/hosted/wrangler.template.jsonc`.
