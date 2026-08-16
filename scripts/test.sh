#!/usr/bin/env bash
# Run the TranslixKit unit tests.
#
# Integration tests that need real models or real audio hardware are tagged and excluded
# from this suite; run them explicitly when you want them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/Packages/TranslixKit"

swift test "$@"
