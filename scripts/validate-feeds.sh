#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEED_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/buddy-feed-check.XXXXXX")"
trap 'rm -rf "$FEED_BUILD"' EXIT
swiftc -parse-as-library -module-cache-path "$FEED_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/ResetAnnouncements.swift" "$ROOT/Sources/TiboChallenge.swift" \
  "$ROOT/scripts/feed-validation/main.swift" -o "$FEED_BUILD/validate"
if [[ $# -eq 0 ]]; then
  "$FEED_BUILD/validate" "$ROOT/announcements/messages.json" "$ROOT/announcements/tibo-28.json"
else
  "$FEED_BUILD/validate" "$@"
fi
