#!/usr/bin/env bash
# Regenerate the Xcode project and build the app.
#
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail

CONFIG="${1:-Debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null || {
    echo "xcodegen is missing. Install it with: brew install xcodegen" >&2
    exit 1
}

xcodegen generate

xcodebuild \
    -project Tranlix.xcodeproj \
    -scheme Tranlix \
    -configuration "$CONFIG" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath ./DerivedData \
    build

echo "Built: $ROOT/DerivedData/Build/Products/$CONFIG/Tranlix.app"
