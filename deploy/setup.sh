#!/usr/bin/env bash
# setup.sh — deploys a self-hosted PRHub Worker (worker/) into your own Cloudflare account. Guide: AGENTS.md here.
#
# Re-runnable: each step finds what an earlier run made and keeps it. In order:
#   1. checks the tools, the Cloudflare token and the GitHub token;
#   2. finds or creates the R2 bucket `<worker>-diffs`;
#   3. renders wrangler.template.jsonc into deploy/wrangler.jsonc;
#   4. deploys the Worker;
#   5. sets the secrets that are given: GITHUB_TOKEN, PUSH_RELAY_KEY, ANTHROPIC_API_KEY, ASK_GITHUB_TOKEN;
#   6. checks the Worker answers;
#   7. prints a one-time pairing link (and QR code) for PRHub.
#
# Settings come from the environment, or a prompt when run in a terminal:
#   CLOUDFLARE_API_TOKEN   required, secret   Account API token (scopes in AGENTS.md)
#   CLOUDFLARE_ACCOUNT_ID  required           32 hex characters
#   GITHUB_TOKEN           required, secret   fine-grained PAT (permissions in AGENTS.md)
#   WORKER_NAME            default pr-review
#   GITHUB_ORGS            optional           owners PRHub filters to by default, comma-separated
#   PUSH_RELAY_URL         optional           the relay's base URL, from Jai; with PUSH_RELAY_KEY
#   PUSH_RELAY_KEY         optional, secret   this Worker's relay key, rks_…, from Jai
#   ANTHROPIC_API_KEY      optional, secret   key lines, rewrites, and Ask AI's key
#   ASK_AGENT_ID ASK_ENVIRONMENT_ID ASK_VAULT_ID ASK_CREDENTIAL_ID   optional   from `npm run ask-agent`
#   ASK_GITHUB_TOKEN       optional, secret   a read-only PAT for Ask AI's agent (else it gets GITHUB_TOKEN)
#   REVIEW_SLA_UTC_OFFSET_HOURS REVIEW_SLA_HOURS REVIEW_SLA_WEEKDAYS   optional   review SLA week
#
# A secret left unset is left as it is on the Worker: a re-run without it keeps the old value. Secrets are never
# printed and never put in argv.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
config="$here/wrangler.jsonc"

say() { printf '==> %s\n' "$*" >&2; }
die() { printf 'setup.sh: %s\n' "$*" >&2; exit 1; }

# ask NAME "prompt" [secret]: keeps an existing value, else prompts in a terminal, else fails.
ask() {
  local name="$1" prompt="$2" secret="${3:-}" value
  value="${!name:-}"
  if [ -z "$value" ]; then
    [ -t 0 ] || die "$name is not set (no terminal to ask in)"
    if [ "$secret" = secret ]; then read -rsp "$prompt: " value; echo >&2; else read -rp "$prompt: " value; fi
  fi
  [ -n "$value" ] || die "$name is empty"
  printf -v "$name" '%s' "$value"
  export "${name?}"
}

# 1. Tools and settings.
for tool in node npm npx curl jq; do command -v "$tool" >/dev/null || die "$tool is required"; done
ask CLOUDFLARE_API_TOKEN "Cloudflare API token" secret
ask CLOUDFLARE_ACCOUNT_ID "Cloudflare account ID"
[[ "$CLOUDFLARE_ACCOUNT_ID" =~ ^[0-9a-f]{32}$ ]] || die "CLOUDFLARE_ACCOUNT_ID must be 32 lowercase hex characters"
ask GITHUB_TOKEN "GitHub fine-grained personal access token" secret
WORKER_NAME="${WORKER_NAME:-pr-review}"
[[ "$WORKER_NAME" =~ ^[a-z0-9][a-z0-9-]{0,55}$ ]] || die "WORKER_NAME must be lowercase letters, digits and hyphens"
PUSH_RELAY_URL="${PUSH_RELAY_URL:-}"
if [ -n "$PUSH_RELAY_URL" ]; then
  [[ "$PUSH_RELAY_URL" =~ ^https://[^[:space:]/]+/?$ ]] || die "PUSH_RELAY_URL must be https://<host>"
fi

if [ ! -d "$root/worker/node_modules" ]; then say "installing the Worker's dependencies"; (cd "$root/worker" && npm ci --no-audit --no-fund >&2); fi
wrangler() { (cd "$root/worker" && npx --yes wrangler@4 "$@"); }

# Cloudflare API call with the token on stdin; prints the body, fails on success:false.
cf() {
  local method="$1" path="$2" data="${3:-}" args response
  args=(-sS --config - -X "$method" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID$path")
  [ -n "$data" ] && args+=(--data "$data")
  response="$(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$CLOUDFLARE_API_TOKEN" | curl "${args[@]}")"
  [ "$(printf '%s' "$response" | jq -r '.success')" = true ] || die "Cloudflare $method $path failed: $(printf '%s' "$response" | jq -c '.errors')"
  printf '%s' "$response"
}

say "checking the Cloudflare token against account $CLOUDFLARE_ACCOUNT_ID"
subdomain="$(cf GET "/workers/subdomain" | jq -r '.result.subdomain // empty')"
[ -n "$subdomain" ] || die "the account has no workers.dev subdomain: open Workers & Pages in the dashboard once to choose one"
worker_url="https://$WORKER_NAME.$subdomain.workers.dev"

say "checking the GitHub token"
login="$(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" | curl -sS --config - -H 'User-Agent: prhub-setup' https://api.github.com/user | jq -r '.login // empty')"
[ -n "$login" ] || die "GitHub did not accept GITHUB_TOKEN"
say "GitHub token is $login's"

# 2. R2 bucket.
bucket="$WORKER_NAME-diffs"
if cf GET "/r2/buckets?per_page=1000" | jq -e --arg b "$bucket" '.result.buckets[] | select(.name == $b)' >/dev/null; then
  say "found R2 bucket $bucket"
else
  cf POST "/r2/buckets" "$(jq -nc --arg b "$bucket" '{name: $b}')" >/dev/null
  say "created R2 bucket $bucket"
fi

# 3. Render the config. Node does the substitution so any value stays valid JSON.
# shellcheck disable=SC2016
WORKER_NAME="$WORKER_NAME" CLOUDFLARE_ACCOUNT_ID="$CLOUDFLARE_ACCOUNT_ID" R2_BUCKET="$bucket" \
  PUSH_RELAY_URL="${PUSH_RELAY_URL%/}" node -e '
const fs = require("fs");
const [template, out] = process.argv.slice(1);
const names = ["WORKER_NAME", "CLOUDFLARE_ACCOUNT_ID", "R2_BUCKET", "PUSH_RELAY_URL", "GITHUB_ORGS",
  "REVIEW_SLA_UTC_OFFSET_HOURS", "REVIEW_SLA_HOURS", "REVIEW_SLA_WEEKDAYS",
  "ASK_AGENT_ID", "ASK_ENVIRONMENT_ID", "ASK_VAULT_ID", "ASK_CREDENTIAL_ID"];
const text = fs.readFileSync(template, "utf8").replace(/__([A-Z0-9_]+)__/g, (whole, name) => {
  if (!names.includes(name)) throw new Error(`no value for ${whole}`);
  return JSON.stringify(process.env[name] ?? "").slice(1, -1);
});
fs.writeFileSync(out, text);
' "$here/wrangler.template.jsonc" "$config"
say "wrote $config"

# 4. Deploy.
say "deploying $WORKER_NAME"
wrangler deploy --config "$config" >&2 || die "wrangler deploy failed"
say "deployed at $worker_url"

# 5. Secrets: each one given, never echoed.
for name in GITHUB_TOKEN PUSH_RELAY_KEY ANTHROPIC_API_KEY ASK_GITHUB_TOKEN; do
  if [ -n "${!name:-}" ]; then
    printf '%s' "${!name}" | wrangler secret put "$name" --config "$config" >/dev/null 2>&1 || die "could not set $name"
    say "set $name"
  fi
done

# 6. Check. Secrets take a few seconds to reach the new version.
sleep 5
[ "$(curl -sS "$worker_url/")" = "hello world" ] || die "$worker_url/ did not answer hello world"
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$worker_url/prs")" = 401 ] || die "$worker_url/prs did not answer 401 without a bearer"
say "the Worker answers"

# 7. Pairing link.
(cd "$root/worker" && node scripts/pair.mjs --worker "$worker_url" --config "$config")

printf '\nWorker: %s\nGitHub: %s\n' "$worker_url" "$login" >&2
