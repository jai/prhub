#!/bin/zsh
# What happened to one Ask turn, from Workers Logs: every `ask_event` line with its id (docs/api.md, "Tracing an Ask").
#   scripts/ask-trace.sh <turn id, or its first 8 characters from the chat's failure line> [worker] [hours back]
# worker: the Worker's name, `prhub` (hosted, the default) or `agent-pager`. CLOUDFLARE_API_TOKEN and
# CLOUDFLARE_ACCOUNT_ID come from the environment, else from ~/.credentials/cloudflare (CLOUDFLARE_API_TOKEN=…,
# CLOUDFLARE_ACCOUNT_ID=…). Prints one line a stage: time, stage, milliseconds since the turn began, then the fields.
set -euo pipefail
turn=${1:?usage: scripts/ask-trace.sh <turn id> [worker] [hours back]}
worker=${2:-prhub}
hours=${3:-24}
read_cred() { awk -F= -v name="$1" '$1 == name {sub(/^[^=]*=/, ""); print; exit}' "$HOME/.credentials/cloudflare" 2>/dev/null }
token=${CLOUDFLARE_API_TOKEN:-$(read_cred CLOUDFLARE_API_TOKEN)}
account=${CLOUDFLARE_ACCOUNT_ID:-$(read_cred CLOUDFLARE_ACCOUNT_ID)}
[[ -n $token && -n $account ]] || { echo "ask-trace: no Cloudflare token or account id" >&2; exit 2; }
now=$(( $(date +%s) * 1000 ))
query=$(jq -n --arg worker "$worker" --arg turn "$turn" --argjson from $(( now - hours * 3600000 )) --argjson to $now '{
  queryId: "ask-trace", timeframe: {from: $from, to: $to}, view: "events", limit: 100,
  parameters: {filters: [
    {key: "$metadata.service", operation: "eq", type: "string", value: $worker},
    {key: "$metadata.message", operation: "includes", type: "string", value: "ask_event"},
    {key: "turn", operation: "includes", type: "string", value: $turn}]}}')
curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/$account/workers/observability/telemetry/query" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$query" \
  | jq -r '.result.events.events // [] | sort_by(.timestamp) | if length == 0 then "no ask_event lines for that turn" else
      .[] | [(.timestamp / 1000 | floor | strftime("%Y-%m-%d %H:%M:%SZ")), .source.stage, ((.source.ms // "") | tostring),
        (.source | del(.message, .stage, .ms) | tostring)] | @tsv end'
