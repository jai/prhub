# Deploying the hosted PRHub Worker

The hosted Worker is the one everyone signs in to with the PRHub GitHub App ([api.md, "Hosted
sign-in"](api.md#hosted-sign-in); [plans/github-app.md](plans/github-app.md)). It is the `worker/` code with
`HOSTED=on`, deployed as `prhub` on Jai's personal Cloudflare account, at `https://prhub.jai-f89.workers.dev` until a
custom domain is chosen. Self-hosted Workers use [deploy/AGENTS.md](../deploy/AGENTS.md) instead.

## Before the first deploy

- The GitHub App exists ([plans/github-app.md, "Creating the App"](plans/github-app.md#creating-the-app)) and its
  credentials are in the password manager item `PRHub GitHub App`.
- The Cloudflare account has the Workers Paid plan (Durable Objects with SQLite) and R2.
- A Cloudflare API token for that account with Workers Scripts Edit, Workers R2 Storage Edit and Account Settings
  Read, in the environment as `CLOUDFLARE_API_TOKEN`. Never print it.

## Configuration

Vars, filled into `deploy/hosted/wrangler.template.jsonc` (the rest of its vars are fixed there):

| Placeholder | Value |
|---|---|
| `__CLOUDFLARE_ACCOUNT_ID__` | The account's ID |
| `__GITHUB_APP_ID__` | The App's App ID |
| `__GITHUB_APP_CLIENT_ID__` | The App's client ID (`Iv…`) |
| `__APNS_KEY_ID__` | The ID of Jai's APNs key |

Secrets, each with `wrangler secret put`, from the password manager:

| Secret | Value |
|---|---|
| `GITHUB_APP_CLIENT_SECRET` | The App's client secret |
| `GITHUB_APP_PRIVATE_KEY` | The App's private key as PKCS#8: `openssl pkcs8 -topk8 -nocrypt -in <key>.pem` |
| `WEBHOOK_SECRET` | The App's webhook secret |
| `TOKEN_ENCRYPTION_KEY` | `k1:` and `openssl rand -base64 32`; rotation in [api.md, "Tokens"](api.md#tokens) |
| `APNS_KEY_P8` | Jai's APNs key (`.p8`) |
| `FEEDBACKKIT_TOKEN` | The FeedbackKit Worker's `CALLER_TOKEN` ([featurekit.md](featurekit.md)): Feedback goes there |

No `GITHUB_TOKEN` and no `ANTHROPIC_API_KEY`: each person acts with their own token, and AI runs on their own key.
`CLAUDE_CODE_OAUTH_TOKEN` (a secret) runs key lines and rewrites on Jai's subscription, for `SUBSCRIPTION_LOGINS` only.
The deploy builds the Agent SDK container from `agent/Dockerfile`, so it needs Docker.

Limits take their hosted defaults ([api.md, "Limits"](api.md#limits)). To change one, add its `LIMIT_*` var to the
rendered config's `vars` and deploy again. `GET /device/config` shows the limits in force, and a value the Worker
cannot use is in `/events` as `limits_config_error`.

## Deploy

From the repo root:

```sh
(cd worker && npm ci && npm test && npm run typecheck)
npx wrangler@4 r2 bucket create prhub-hosted          # once
sed -e "s/__CLOUDFLARE_ACCOUNT_ID__/$ACCOUNT_ID/" -e "s/__GITHUB_APP_ID__/$APP_ID/" \
    -e "s/__GITHUB_APP_CLIENT_ID__/$CLIENT_ID/" -e "s/__APNS_KEY_ID__/$APNS_KEY_ID/" \
    deploy/hosted/wrangler.template.jsonc > deploy/hosted/wrangler.jsonc
cd worker
npx wrangler@4 deploy --config ../deploy/hosted/wrangler.jsonc
```

Then each secret, piped so it is never printed or kept in the shell history:

```sh
<read the value from the password manager> | npx wrangler@4 secret put <NAME> --config ../deploy/hosted/wrangler.jsonc
```

Until every secret and binding is there, every route but `/` answers `503 not_configured`.

## Check

```sh
URL=https://prhub.jai-f89.workers.dev
curl -s $URL/                                                     # hello world
curl -s $URL/.well-known/apple-app-site-association               # {"webcredentials": …}
curl -s -o /dev/null -w '%{http_code}\n' "$URL/auth/github/start"  # 400: no state or challenge
curl -s -o /dev/null -w '%{http_code}\n' $URL/prs                  # 401: no session
```

Then sign in from the app, open the App's Advanced settings on GitHub, and check that recent deliveries answer `202`.
`GET /events` with the session shows `polled` every 10 minutes, and `rate_limited` if GitHub asked a token to wait.
Logs: `npx wrangler@4 tail prhub --config ../deploy/hosted/wrangler.jsonc --format pretty`.

`deploy/hosted/wrangler.jsonc` is gitignored; never commit it or any value above.

## Rotating the token key

`TOKEN_ENCRYPTION_KEY` seals each person's GitHub tokens and Anthropic key. Rotate it when it may have leaked, and
otherwise once a year.

1. Make a new key and store it in the password manager item `PRHub GitHub App` beside the old one. Give it the next
   id: `k2` after `k1`.

   ```sh
   echo "k2:$(openssl rand -base64 32)"
   ```

2. Put the new key first and keep the old one after it, comma-separated, and set the secret:

   ```sh
   <read "k2:…,k1:…" from the password manager> | npx wrangler@4 secret put TOKEN_ENCRYPTION_KEY --config ../deploy/hosted/wrangler.jsonc
   ```

   The new key seals from now on. Both keys open.
3. Wait for two poll intervals (`poll_interval_minutes`, 10 by default). Each signed-in account's poll seals its
   values again with the new key. A signed-out account holds no token or key.
4. Check. In your own `/events`, `token_keys` shows `"current": "k2"` and what was sealed again. Across accounts,
   `npx wrangler@4 tail prhub --config ../deploy/hosted/wrangler.jsonc --search token_keys` shows each account's report
   as its poll runs; any report with a non-empty `stale` names values still on the old key.
5. When no report has a non-empty `stale`, set the secret to the new key alone (`k2:…`), and delete the old key from
   the password manager.

If an old key leaves the keyring too soon, the values it sealed no longer open. Those accounts report them in
`stale`, and the Worker answers `503 github_unavailable` for them until the old key is back in the keyring. Each
person can also sign in again, which seals new tokens with the new key.
