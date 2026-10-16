#!/usr/bin/env bash
# Runs the terminal URL checks against SwiftTerm 1.13.0, the version the app pins.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/scripts/terminal-url"
SWIFT="${ROAMTTY_SWIFT:-swift}"
export ROAMTTY_SWIFTTERM="${ROAMTTY_SWIFTTERM:-$HARNESS/SwiftTerm}"
if [ ! -d "$ROAMTTY_SWIFTTERM" ]; then
  git clone --quiet --depth 1 --branch v1.13.0 https://github.com/migueldeicaza/SwiftTerm.git "$ROAMTTY_SWIFTTERM"
fi
# SwiftTerm's manifest skips its benchmark dependency on CI.
cd "$HARNESS" && GITHUB_ACTIONS=true "$SWIFT" run -c release TerminalUrlChecks
