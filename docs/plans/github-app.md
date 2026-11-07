# GitHub App: hosted PRHub

Status: plan, 2026-11-07 (step 6a). Nothing is built and the App does not exist yet. Jai creates it with
`deploy/github-app/create.py` ("Creating the App" below). Self-hosting stays as `docs/plans/distribution.md` describes.

## Goal

Someone installs PRHub, taps Sign in with GitHub, and reviews their PRs. They need no Cloudflare account, no PAT and
no coding agent. One Worker on Jai's Cloudflare account serves everyone, through one public GitHub App. The app keeps
pairing with a self-hosted Worker for people who want their data on their own account.

## Architecture

- **One Worker, `prhub`, on Jai's personal Cloudflare account** (`Jai@govindani.com's Account`), at
  `https://prhub.<account>.workers.dev` until a custom domain is chosen. It runs the `worker/` code. Hosted mode is on
  when the App's secrets are set, the same rule every optional feature in that Worker follows. It needs the Workers
  Paid plan.
- **One Durable Object per person, named `user:<GitHub user id>`.** A login can change, and the id cannot. It holds what
  `PrIndex` holds today for Jai (rows, versions, pushes, devices) plus that person's tokens and settings. `AiJobs` takes
  the same name.
- **One Durable Object per installation, named `installation:<id>`.** It receives that installation's webhooks and
  marks the PR in the user objects it concerns: the PR's author, its requested reviewers, and every person whose list
  holds it. A person joins the installations from `GET /user/installations` at sign-in and on each app open.
- **The person's own token for everything they see or do.** The list searches (`@me`), PR reads and every write use
  their user access token. GitHub then shows them as the author, with the App's badge, and answers only with what they
  can see. Fields such as `viewerViewedState`, `viewerCanResolve` and `viewerDidAuthor` exist only for a person.
- **Installation tokens where no person acts, always narrowed.** An installation token reads every repo in the
  installation, including repos a given person cannot see, so it never answers a person's request directly.
  - Ask AI's checkout: one repo, read only, one hour. This replaces the Ask GitHub App in `ask.ts`.
  - Later, a shared copy of a PR's diff and files at one commit, read once for all its reviewers. A person gets it only
    after their own token found the PR.
- **Webhooks need no token.** GitHub signs each delivery with the App's webhook secret, and `/github/webhook` checks it
  as it does today.
- **The poll becomes a safety net.** Each user object sets its own alarm, every 10 minutes, and syncs when the app
  opens. Webhooks bring changes within seconds. The one-minute cron, which walks one person, goes.
- **Tokens are encrypted at rest.** The Worker uses AES-256-GCM through Web Crypto with a key from a Worker secret.
  The user id is the associated data, and a key version prefix lets the key rotate. No token goes to the phone, R2 or a log.
- **The app's bearer is a session secret.** After sign-in the Worker returns `<user id>.<random>`, and the app sends it
  the way it sends a paired device secret today. The id finds the user object, which checks the SHA-256 of the rest.
- **Push goes straight to APNs.** PRHub is on Jai's Apple team (`K2P9X73SPT`), so the hosted Worker sends with Jai's
  APNs key and the topic `com.jaigovindani.prreview`, the existing `APNS_*` path. The relay stays for self-hosted
  Workers only.
- **Deleting an account deletes everything.** Delete Account in Settings revokes the authorization
  (`DELETE /applications/{client_id}/grant`), clears the user object, deletes the person's R2 objects and leaves each
  installation object. The same runs when the `github_app_authorization` event says the person revoked the App on
  GitHub.

## Tokens

GitHub's rules, and what the Worker does with each:

- A user access token (`ghu_`) lasts 8 hours. Its refresh token (`ghr_`) lasts 6 months, and each refresh returns a
  new pair with a new 6 months. While the Worker keeps polling for a person, their token stays fresh. They sign in
  again only after 6 months with no refresh.
- A refresh kills the pair it used, so two refreshes at once sign the person out. The user object refreshes, one at a
  time, 5 minutes before expiry. `bad_refresh_token` marks the person signed out and sends a push that asks them to
  sign in again.
- A user token can do only what both the App's permissions and the person's own access allow. It reaches only
  accounts where the App is installed: authorizing the App installs nothing.
- An installation token lasts 1 hour. The Worker always mints it with `repositories` and `permissions`. No
  installation token it mints can write.
- Rate limits. A user token shares the person's 5,000 REST requests and 5,000 GraphQL points an hour with their own
  PATs, `gh` and other apps. An installation gets 5,000 an hour, plus 50 per repo past 20 and 50 per org member past
  20, up to 12,500. 6c measures the poll's cost per person, with a target under a tenth of their hour. The Worker
  backs off when `x-ratelimit-remaining` runs low and when GitHub sends `retry-after`.
- The App may make 2,000 token requests an hour. At one refresh per person every 8 hours, that is about 16,000 active
  people.

## Permissions

Each permission maps to the calls `worker/src` makes today. Nothing else is requested.

Repository permissions:

- **Metadata: read.** GitHub requires it of every App. Repo names and `viewerDefaultMergeMethod`.
- **Pull requests: read and write.**
  - Reads: the three list searches and the merged searches (`github.ts`), PR detail with reviews, threads, files,
    labels and review-request events, the diff (`GET /repos/{r}/pulls/{n}` as a diff), and `pr-states.ts`.
  - Writes (`write.ts`): reviews, line comments, thread replies, resolve and unresolve, file viewed, update branch,
    removing a review request, the description and its checkboxes.
  - Conversation comments (`POST /repos/{r}/issues/{n}/comments`): GitHub accepts Pull requests write in place of
    Issues write.
  - The `pull_request`, `pull_request_review`, `pull_request_review_comment` and `pull_request_review_thread` events.
- **Contents: read and write.**
  - Read: `.policy.yml` (`policy-github.ts`), the lines around a key line, and the rewrite's writing guide (`ai.ts`).
  - Write: merge. `PUT /repos/{r}/pulls/{n}/merge` needs Contents write.
- **Workflows: write.** GitHub refuses a merge or an update branch that changes `.github/workflows/` without it. It
  matches the PAT's `workflow` scope in `deploy/AGENTS.md`.
- **Checks: read.** Check runs in a PR's checks (`statusCheckRollup` contexts) and the `check_suite` event.
- **Commit statuses: read.** Status contexts, PolicyBot's review state among them, and the `status` event.
- **Issues: read.** The `issue_comment` event requires it. Ask AI reads issues a PR links to.
- **Actions: read.** Ask AI reads CI runs and their logs. It is the read-only set `ask.ts` mints today.

Organization permissions:

- **Members: read.** Names of teams asked to review (`reviewRequests` on a `Team`), and the team and org membership
  `.policy.yml` rules need (`/orgs/{org}/teams/{slug}/memberships/{login}`, `/orgs/{org}/members/{login}`). It matches
  the PAT's `read:org`.

Account permissions: none. `GET /user` needs none.

Contents write and Workflows write are what an org owner questions on the install screen. They exist for merge
alone. Without them, everything except merging from the phone still works.

## Events

- Subscribed: `pull_request`, `pull_request_review`, `pull_request_review_comment`, `pull_request_review_thread` and
  `issue_comment`, today's set (`webhook.ts`).
- Also subscribed: `check_suite` and `status`. The hosted poll runs every 10 minutes, not every minute, so a PR's
  checks and PolicyBot's state must arrive as events. `check_suite` sends one `completed` per CI app per commit.
- Left out: `check_run` and `workflow_run`. They were 91% of PolicyBot's deliveries.
- Sent to every App without a subscription: `installation`, `installation_repositories` and
  `github_app_authorization`.

## What a GitHub App cannot do that a PAT can

- **Reach an org the App is not installed on.** A classic `repo` PAT covers every org the person belongs to. The App
  needs an org owner to install it, and a member can only request it. Onboarding shows which orgs have the App and
  links to the request page for the rest.
- **Reach repos left out of a "selected repositories" install.**
- **Find PRs in repos without the App.** Search with a user token returns only installed repos.
- **Merge workflow changes without Workflows write**, as above.
- **Read team names without Members read.** Org owners approve it as part of the install.
- **Pass SAML single sign-on without an active session.** The person signs in to the org's SSO on github.com, then
  signs in to PRHub again.

Reviews, approvals, comments and merges made with a user token count as the person's own. PolicyBot and branch
protection treat them as they treat the same action on the web.

## Sign-in in the app

1. The person taps Sign in with GitHub. The app makes a random `state` and a PKCE verifier, and keeps both in memory.
2. The app opens `ASWebAuthenticationSession` (iOS 17.4 or later) on
   `https://github.com/login/oauth/authorize?client_id=…&redirect_uri=https://<worker>/auth/github/callback&state=…&code_challenge=…&code_challenge_method=S256`,
   with the callback `.https(host: "<worker host>", path: "/auth/github/callback")`.
3. GitHub asks the person to authorize PRHub, then redirects to the callback. The session catches that redirect inside
   the app, so the code does not reach the Worker by that route.
4. The app checks `state`, then sends `POST /auth/github/token` with `{code, code_verifier}`.
5. The Worker trades them, with its client secret, at `https://github.com/login/oauth/access_token`. It reads
   `GET /user` for the id and login, stores the encrypted tokens in `user:<id>`, and answers with the session secret.
6. The app keeps the session secret and the Worker URL in the keychain and reads `GET /device/config`.
7. With no installation on an owner the person cares about, the app shows Install PRHub on GitHub, which opens
   `https://github.com/apps/<slug>/installations/new` in a second session. When it closes, the app reads the
   installations again.

The callback URL choice:

- **An HTTPS callback on the Worker's own host.** Only an app with that host in its associated domains
  (`webcredentials:<host>`) can catch it. The Worker serves `/.well-known/apple-app-site-association`. Any app can
  claim a custom scheme such as `prhub://`, and GitHub always shows its account picker for one.
- **The callback route also serves a page.** `request_oauth_on_install` sends a person who installed from github.com
  to the callback with a code and no app waiting. The page says the App is installed and offers Open PRHub. It does
  not trade the code.
- **The host is fixed in each app build.** The callback host, the associated domain and the App's callback URL must
  move together. A custom domain before 6d ships avoids an app update later.

## Hosted and self-hosted together

- First run offers both: Sign in with GitHub, and Connect your own Worker (the `prhub://setup` link or QR code).
- The app stores one connection: a mode, a Worker URL and a bearer. After sign-in, both kinds of Worker answer the
  same routes (`/prs`, `/prs/merged`, `/prs/{owner}/{repo}/{n}/…`, `/device/config`, `/device/register`, `/device/event`).
  The PR screens do not know which kind of Worker they talk to.
- `GET /device/config` gains `"hosted": true` on the hosted Worker, for Settings: Delete Account there, Disconnect on
  a self-hosted one.
- Switching signs out of one and into the other. Nothing moves between them, because a self-hosted Worker's data is
  on the person's own account.
- Jai's `pr-viewer` on the work account stays a self-hosted Worker with `APP_TOKEN`.

## App Review

- **Sign in with Apple is not required.** Guideline 4.8 does not require another login service when "Your app is a
  client for a specific third-party service and users are required to sign in to their mail, social media, or other
  third-party account directly to access their content." PRHub is a client for GitHub, and the PRs are the person's
  content on GitHub. The review notes say so.
- **Account deletion is required.** Guideline 5.1.1(v): "If your app supports account creation, you must also offer
  account deletion within the app." Signing in with GitHub creates a PRHub account on the Worker, so Delete Account
  ships with 6d.
- **Tokens held on the server are a review risk.** Guideline 5.1.1(v) also says "An app may not store credentials or
  tokens to social networks off of the device". GitHub is not a social network in Apple's list, but a reviewer may
  read it that way. The review notes explain why the Worker holds the token: to notice changes and push while the app
  is closed. The notes also point to Delete Account and to revoking the App on GitHub.
- **Reviewers keep "Try with sample PRs"**, which runs with no account. A demo GitHub account with one installed
  sample repo lets them test sign-in.

## Privacy and security work

- Rewrite the privacy policy (`PRIVACY.md`) for the hosted service. Name what the Worker
  stores (GitHub id and login, tokens, cached PR content, device tokens, events) and who processes it (Cloudflare,
  Apple, Anthropic, GitHub). Update the App Store privacy answers to match.
- Encrypt tokens from the first stored token, in 6b. Document key rotation, and store the key in the password manager.
- Delete cached PR content when a PR closes plus 30 days, with an R2 lifecycle rule as a backstop.
- On `installation` `deleted` or `suspend`, drop the rows from that installation's repos in each member's object.
- Keep tokens, PR bodies and diffs out of logs and `/events`.
- Rate-limit `POST /auth/github/token`, the write route and Ask per person, in the user object.
- Test isolation between people: person B never receives a row, diff or file that only person A's token can read.
- Cap each person's mirror: rows, R2 bytes, and the existing size cap on a diff.
- Keep the App's private key, client secret, webhook secret and token key in Worker secrets and the password manager only.

## AI cost controls

Key lines, rewrites and Ask run on Jai's Anthropic key in the hosted Worker, so every person's use is Jai's bill.

- AI is off by default per person. Jai turns it on from an allowlist var until there is a price or a quota.
- A monthly budget per person, in the user object. Key-line runs, rewrites and Ask sessions each count against it.
  At the limit, `/device/config` turns the feature off for that person.
- Ask keeps its $2 cap per PR session and adds a cap on new sessions per day.
- Key lines are preloaded only for PRs awaiting the person's review and only within the diff size cap. Other context
  sizes run on request, as today.
- A Worker var turns all AI off at once. The Anthropic workspace for the hosted Worker has its own spend limit.
- Later, a person may bring their own Anthropic key, stored encrypted like a GitHub token.

## Work, in order

Easiest first. 6b goes first, because everything else needs a signed-in person. 6d and 6e then run beside 6c.

1. **6a: this plan and the App manifest** (done). `deploy/github-app/manifest.json`, `deploy/github-app/create.py`.
2. **6b: sign-in and refresh on the Worker.** Medium, about 2 days. Serial, first.
   - `POST /auth/github/token`, the callback page and the association file.
   - The user object storing encrypted tokens, refreshing them one at a time, and minting session secrets.
   - `DELETE /account`, and the `github_app_authorization` event.
   - The contract in `docs/`, so 6d can start against it.
3. **6d: Sign in with GitHub in the app.** Medium, about 2 days. Parallel with 6c, after 6b's contract.
   - The onboarding choice, the authentication session, PKCE, the install prompt and the keychain connection.
   - Delete Account in Settings, and the signed-out push.
4. **6e: encryption, deletion, privacy and limits.** Medium, about 2 days. Parallel with 6c.
   - Key rotation, data retention and installation clean-up.
   - Per-person rate limits and AI budgets.
   - The privacy policy, App Store privacy answers and review notes.
5. **6c: the multi-tenant Worker.** Large, about 4 to 5 days. Serial after 6b.
   - Pass a per-person GitHub context through the code where it reads `env.GITHUB_TOKEN` and `GITHUB_LOGIN` today.
   - Name objects by user id, replace the cron with per-person alarms, and add the installation objects and webhook
     routing.
   - Use installation tokens for Ask, and measure the poll's rate-limit cost per person.

## Creating the App

The App lives on Jai's personal account (`jai`). GitHub App names are unique across GitHub and cannot match another
account's login. `prhub` and `pr-hub` are GitHub user accounts, so neither can be the App's name. On 2026-11-07 no
account or public App used `prhub-app`, `prhubapp`, `prhub-ios`, `prhub-for-ios`, `prhub-review`, `prhub-mobile`,
`getprhub` or `prhubhq`. A private App's page also answers 404, so GitHub's form is the final check. The manifest
proposes `PRHub App` (shown on GitHub as `prhub-app`), and the form lets Jai change it.

1. On a Mac where Jai is signed in to github.com as `jai`, from the repo root:

   ```sh
   python3 -I deploy/github-app/create.py --worker https://prhub.<account>.workers.dev
   ```

   Use the custom domain instead, if one is chosen by then. `--dry-run` prints the manifest.
2. The browser opens GitHub's Create GitHub App form with everything filled in. Click **Create GitHub App**. The
   script then writes the credentials to `tmp/github-app/prhub-app.json`, mode 0600, and prints which fields came back.
3. On the App's settings page:
   - Optional features: confirm User-to-server token expiration is on. It is the default.
   - Callback URL: confirm wildcard matching is off.
   - Leave device flow off.
   - Upload the PRHub icon.
4. Store the credentials in the operator's password manager as one item titled `PRHub GitHub App`: App ID, client
   ID, client secret, webhook secret, and the private key as a file.
5. Delete `tmp/github-app/prhub-app.json`. Never commit any of it.
6. In 6b the same values become the hosted Worker's settings: `GITHUB_APP_ID` and `GITHUB_APP_CLIENT_ID` as vars, and
   `GITHUB_APP_CLIENT_SECRET`, `GITHUB_APP_PRIVATE_KEY` and `WEBHOOK_SECRET` as secrets (`wrangler secret put`). GitHub
   gives the key as PKCS#1, and Web Crypto needs PKCS#8 (`openssl pkcs8 -topk8 -nocrypt`), as for `ASK_GITHUB_APP_KEY`.
   6b adds `TOKEN_ENCRYPTION_KEY`, a new random 32-byte key stored in the same password-manager item.

The webhook URL fails until the hosted Worker is deployed. GitHub records the failed deliveries and changes nothing.

## Needs Jai

- The App's name: `PRHub App` (`prhub-app`) or another free name.
- A custom domain for the hosted Worker before 6d, since the callback host is fixed in each app build.
- Contents write and Workflows write: keep them for merge from the phone, or drop them so org owners approve faster.
- AI on the hosted Worker: allowlist only, a quota per person, a paid tier, or bring-your-own key.
- Whether Jai's own phone moves to the hosted Worker or keeps `pr-viewer` on the work account.
