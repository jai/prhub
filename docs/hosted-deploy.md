# Deploying the hosted PRHub Worker

The hosted Worker is the one everyone signs in to with the PRHub GitHub App ([api.md, "Hosted
sign-in"](api.md#hosted-sign-in); [plans/github-app.md](plans/github-app.md)). It is the `worker/` code with
`HOSTED=on`, deployed as `prhub` on Jai's personal Cloudflare account, at `https://prhub.jai-f89.workers.dev` until a
custom domain is chosen. Self-hosted Workers use [deploy/AGENTS.md](../deploy/AGENTS.md) instead.

## Before the first deploy

- The GitHub App exists ([plans/github-app.md, "Creating the App"](plans/github-app.md#creating-the-app)) and its
  credentials are in the password manager item `PRHub GitHub App`.
- The Cloudflare account has the Workers Paid plan (Durable Objects with SQLite, rate limiting) and R2.
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

No `GITHUB_TOKEN` and no `ANTHROPIC_API_KEY`: each person acts with their own token, and AI runs only on their own key.

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
