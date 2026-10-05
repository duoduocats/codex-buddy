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
# Compile both app-icon resources with Apple's asset compiler. Settings and
# sharing use a separate canonical mark so app-icon changes cannot alter them.
ICON_COMPILER="${ICON_COMPILER:-$(xcrun --find actool 2>/dev/null || true)}"
if [[ ! -x "$ICON_COMPILER" && -x /Applications/Xcode.app/Contents/Developer/usr/bin/actool ]]; then
  ICON_COMPILER=/Applications/Xcode.app/Contents/Developer/usr/bin/actool
fi
if [[ ! -x "$ICON_COMPILER" ]]; then
  echo 'Xcode 26 or later is required to compile the native layered app icon.' >&2
  exit 1
fi
mkdir -p "$BUILD/icon-assets"
"$ICON_COMPILER" "$ROOT/Resources/AppIcon.icon" --compile "$BUILD/icon-assets" \
  --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "$BUILD/icon-info.plist" --output-format human-readable-text
cp "$BUILD/icon-assets/Assets.car" "$APP/Contents/Resources/Assets.car"
swiftc -module-cache-path "$BUILD/module-cache" -swift-version 5 -Osize \
  -target arm64-apple-macosx13.0 -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/CodexBuddy"
strip -x "$APP/Contents/MacOS/CodexBuddy"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/icon-assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/BuddyMark.png" "$ROOT/Resources/BuddyHead.png" "$ROOT/Resources/install-update.sh" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
