#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build}"
APP="$BUILD/Codex Buddy.app"
# Use a clean build directory; never retain a helper from an older release.
if [[ -d "$APP/Contents/Helpers" ]]; then
  echo 'Use a fresh BUILD_DIR for this native release.' >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -module-cache-path "$BUILD/module-cache" -swift-version 5 -Osize \
  -target arm64-apple-macosx13.0 -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement \
  "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/CodexBuddy"
strip -x "$APP/Contents/MacOS/CodexBuddy"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/BuddyHead.png" "$ROOT/Resources/install-update.sh" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
