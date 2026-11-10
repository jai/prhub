#!/bin/sh
# Runs every charter in charters.txt: one `e2e explore` each, one per simulator, in parallel.
# Video is off: four simulators recording at once time out. BUGBASH_VIDEO=1 turns it on.
# Model: the ChatGPT sign-in (`npx e2e login openai`) when present, else OPENAI_API_KEY. E2E_MODEL picks the model id.
set -eu
# A colouring GREP_OPTIONS would write escape codes into the slugs and ids.
unset GREP_OPTIONS GREP_COLOR
cd "$(dirname "$0")"
# Booted `PRHub E2E` simulators only; BUGBASH_PARALLEL caps how many (default 2: more time out on a busy Mac).
PRHUB_E2E_SIMS=$(xcrun simctl list devices | grep 'PRHub E2E' | grep Booted | grep -oE '[0-9A-F-]{36}' | head -n "${BUGBASH_PARALLEL:-2}" | paste -sd, -)
export PRHUB_E2E_SIMS
SIMS=$(echo "$PRHUB_E2E_SIMS" | tr ',' '\n' | grep -c .)
[ "$SIMS" -gt 0 ] || { echo "No 'PRHub E2E' simulators: run ./sims.sh first" >&2; exit 2; }
OUT=.e2e/bugbash/${BUGBASH_RUN:-$(date +%Y%m%d-%H%M)}
mkdir -p "$OUT"
rm -rf .e2e/bugbash/sim-*.lock .e2e/bugbash/sim-*.started
CHARTERS=${1:-charters.txt}
# Each charter takes the next simulator: the target `<mode>-<n>`.
n=0
grep -v '^#' "$CHARTERS" | grep . | while IFS='|' read -r slug mode agent charter; do
  n=$((n % SIMS + 1))
  printf '%s\0%s\0%s\0%s\0' "$slug" "$mode-$n" "$agent" "$charter"
done | xargs -0 -n 4 -P "$SIMS" sh -c '
  # A slot holds one simulator: wait while another charter on it still runs.
  sim=${2##*-}; lock=".e2e/bugbash/sim-$sim.lock"; while ! mkdir "$lock" 2>/dev/null; do sleep 5; done
  # The first round starts 30 s apart: one agent-device daemon boots every simulator and times out under four at once.
  [ -e ".e2e/bugbash/sim-$sim.started" ] || { touch ".e2e/bugbash/sim-$sim.started"; sleep $(( (sim - 1) * 30 )); }
  # Exit 2 or 3 is setup or the environment, not findings: try once more.
  for try in 1 2; do
    npx e2e explore "$4" --config e2e.bugbash.config.ts --target "$2" --agent "$3" --output "'"$OUT"'/$1" \
      --max-steps "${BUGBASH_STEPS:-15}" --timeout "${BUGBASH_TIMEOUT:-900000}" ${BUGBASH_VIDEO:+--video} --reporter list,markdown \
      < /dev/null > "'"$OUT"'/$1.log" 2>&1 && code=0 || code=$?
    [ "$code" -ge 2 ] || break
  done
  echo "$1 exit $code"; rmdir "$lock"' _
echo "Logs and reports: $OUT"
