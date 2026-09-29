#!/usr/bin/env bash
# Build a Release copy of Tranlix and install it into /Applications, replacing the old one.
#
# This is for personal use on this machine. The app is signed with the development
# certificate that project.yml already configures, so it is fast and needs no notarization.
# To produce something for another Mac, use scripts/release.sh instead.
#
# Usage: scripts/install.sh [--no-launch]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/Applications/Tranlix.app"
BUILT="$ROOT/DerivedData/Build/Products/Release/Tranlix.app"

LAUNCH=1
case "${1:-}" in
    --no-launch) LAUNCH=0 ;;
    "") ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac

"$ROOT/scripts/build.sh" Release

[[ -d "$BUILT" ]] || { echo "error: build output not found at $BUILT" >&2; exit 1; }
codesign --verify --deep --strict "$BUILT"

# A running copy keeps the microphone and the process tap open, and replacing its bundle
# underneath it leaves a process that no longer matches what is on disk.
if pgrep -x Tranlix >/dev/null 2>&1; then
    echo "Stopping the running Tranlix instance..."
    pkill -x Tranlix || true
    for _ in $(seq 1 20); do
        pgrep -x Tranlix >/dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -9 -x Tranlix 2>/dev/null || true
fi

# Copy next to the destination first and swap, so a failed copy never leaves
# /Applications without a working app.
STAGED="$DEST.installing"
rm -rf "$STAGED"
ditto "$BUILT" "$STAGED"
rm -rf "$DEST"
mv "$STAGED" "$DEST"

VERSION="$(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(defaults read "$DEST/Contents/Info.plist" CFBundleVersion)"
echo "Installed: $DEST ($VERSION, build $BUILD)"

if (( LAUNCH )); then
    open "$DEST"
fi
