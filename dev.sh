#!/bin/bash
# Rebuild and run the DEV app ("Multee Dev") — a separate bundle from any real/brew Multee, so it
# never clashes with one you use day-to-day. Installs to /Applications and waits for the self-shot.
set -e
cd "$(dirname "$0")"
CONFIG="${1:-debug}"

# Match build.sh: debug → "Multee Dev.app", release → "Multee.app".
if [ "$CONFIG" = "debug" ]; then APP="Multee Dev.app"; else APP="Multee.app"; fi
NAME="${APP%.app}"

ERR=$(swift build -c "$CONFIG" 2>&1 | grep -E "error:" | head -20 || true)
if [ -n "$ERR" ]; then echo "BUILD ERRORS:"; echo "$ERR"; exit 1; fi
./build.sh "$CONFIG" >/dev/null 2>&1

osascript -e "quit app \"$NAME\"" 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/Multee" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP"
cp -R "$APP" "/Applications/$APP"
rm -f /tmp/multee-shot.png
open "/Applications/$APP"
for i in $(seq 1 25); do [ -f /tmp/multee-shot.png ] && break; sleep 1; done
sleep 3
pgrep -f "/Applications/$APP/Contents/MacOS/Multee" >/dev/null && echo "OK running ($APP)" || {
  echo "CRASHED"; ls -t ~/Library/Logs/DiagnosticReports/Multee-*.ips 2>/dev/null | head -1; }
