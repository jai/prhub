#!/bin/sh
# Builds PRHub (Debug, Simulator) and installs it on the simulators `PRHub E2E 1` … `PRHub E2E <n>`, making and booting
# any that are missing. Run again after an app change. Usage: ./sims.sh [count, default 4]
set -eu
unset GREP_OPTIONS GREP_COLOR
cd "$(dirname "$0")/../app"
COUNT=${1:-4}
RUNTIME=$(xcrun simctl list runtimes | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | tail -1)
xcodegen generate --spec project.yml --quiet
flowdeck build -w PRHub.xcodeproj -s PRHub -C Debug -S 'iPhone 17' -d build/DerivedData
APP=build/DerivedData/Build/Products/Debug-iphonesimulator/PRHub.app
i=1
while [ "$i" -le "$COUNT" ]; do
  name="PRHub E2E $i"
  udid=$(xcrun simctl list devices | grep -F "$name (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)
  [ -n "$udid" ] || udid=$(xcrun simctl create "$name" "iPhone 17" "$RUNTIME")
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl install "$udid" "$APP"
  echo "$name $udid"
  i=$((i + 1))
done
