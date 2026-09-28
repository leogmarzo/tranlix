#!/usr/bin/env bash
# Build and launch the app, replacing any instance that is already running.
#
# Killing the running instance first is not optional: a second copy would fight the first
# one for the microphone and the Core Audio process tap, and the failure looks like a
# capture bug rather than what it is.
set -euo pipefail

CONFIG="${1:-Debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/build.sh" "$CONFIG"

APP="$ROOT/DerivedData/Build/Products/$CONFIG/Tranlix.app"

if pgrep -x Tranlix >/dev/null 2>&1; then
    echo "Stopping the running Tranlix instance..."
    pkill -x Tranlix || true
    # Give it a moment to release the audio devices before the new one grabs them.
    for _ in $(seq 1 20); do
        pgrep -x Tranlix >/dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -9 -x Tranlix 2>/dev/null || true
fi

open "$APP"
echo "Launched: $APP"
