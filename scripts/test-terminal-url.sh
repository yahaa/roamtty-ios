#!/usr/bin/env bash
# Runs terminal regressions against the same vendored SwiftTerm package as the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/scripts/terminal-url"
SWIFT="${ROAMTTY_SWIFT:-swift}"
cd "$HARNESS"
GITHUB_ACTIONS=true "$SWIFT" run -c release TerminalUrlChecks
GITHUB_ACTIONS=true "$SWIFT" run -c release TerminalWideCellChecks
GITHUB_ACTIONS=true "$SWIFT" run -c release TerminalScrollbackChecks
"$SWIFT" run -c release TerminalMemoryChecks
