#!/usr/bin/env bash
# feedbackkit-e2e.sh — FeedbackKit's test app for the Feedback end-to-end test (issue #51), from the e2e workflow.
#
#   scripts/feedbackkit-e2e.sh token   a token for the test app, signed with its key: 15 minutes
#   scripts/feedbackkit-e2e.sh clean   deletes every chat the test app has (FeedbackKit deletes only the test app's)
#   scripts/feedbackkit-e2e.sh seed-screenshot <text> <jpeg>   a chat whose first message is <text> with that JPEG
#
# Reads FEEDBACKKIT_E2E_URL (the Worker's root) and FEEDBACKKIT_E2E_APP_KEY from the environment. Prints no secret and
# no chat's words: this repo's logs are public.
set -euo pipefail
: "${FEEDBACKKIT_E2E_URL:?}" "${FEEDBACKKIT_E2E_APP_KEY:?}"

token() {
  python3 - <<'PY'
import base64, hashlib, hmac, json, os, time
def b64(data): return base64.urlsafe_b64encode(data).rstrip(b"=").decode()
now = int(time.time())
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
claims = {"iss": "e2e", "sub": "feedbackkit-e2e", "aud": "feedbackkit", "iat": now, "exp": now + 900}
payload = b64(json.dumps(claims, separators=(",", ":")).encode())
key = os.environ["FEEDBACKKIT_E2E_APP_KEY"].encode()
signature = b64(hmac.new(key, f"{header}.{payload}".encode(), hashlib.sha256).digest())
print(f"{header}.{payload}.{signature}")
PY
}

case "${1:-}" in
  token) token ;;
  clean)
    bearer=$(token)
    api() { printf 'header = "Authorization: Bearer %s"\n' "$bearer" | curl -sS --fail --retry 2 --config - "$@"; }
    ids=$(api "$FEEDBACKKIT_E2E_URL/v2/feedback" | jq -r '.threads[]?.id')
    count=0
    for id in $ids; do
      api -X DELETE -o /dev/null "$FEEDBACKKIT_E2E_URL/v2/feedback/$id"
      count=$((count + 1))
    done
    echo "deleted $count test chat(s)"
    ;;
  seed-screenshot)
    text="${2:?text}"; jpeg="${3:?jpeg}"
    bearer=$(token)
    body=$(mktemp)
    python3 -c 'import base64, json, sys; print(json.dumps({"text": sys.argv[1], "client_ref": sys.argv[1], "images": [{"media_type": "image/jpeg", "data": base64.b64encode(open(sys.argv[2], "rb").read()).decode()}]}))' "$text" "$jpeg" > "$body"
    printf 'header = "Authorization: Bearer %s"\n' "$bearer" \
      | curl -sS --fail --retry 2 --config - -H 'content-type: application/json' -d @"$body" "$FEEDBACKKIT_E2E_URL/v2/feedback" > /dev/null
    rm -f "$body"
    echo "seeded a chat with one screenshot"
    ;;
  *) echo "usage: $0 token|clean|seed-screenshot <text> <jpeg>" >&2; exit 2 ;;
esac
