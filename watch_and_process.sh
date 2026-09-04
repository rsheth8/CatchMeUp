#!/usr/bin/env bash
# Compatibility for previously installed launchd jobs. New jobs call the CLI.
set -eu
CATCHUP_WATCH_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATCHUP_WATCH_SCOPE="${2:-${1:-}}"
if [ -n "$CATCHUP_WATCH_SCOPE" ]; then
  exec "$CATCHUP_WATCH_SOURCE/catchup" --no-input watch "$CATCHUP_WATCH_SCOPE" --once
else
  exec "$CATCHUP_WATCH_SOURCE/catchup" --no-input watch --once
fi
