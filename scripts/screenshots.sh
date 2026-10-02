#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_BUILD="${SCREENSHOT_BUILD_DIR:-$(mktemp -d /private/tmp/buddy-screenshots.XXXXXX)}"
OUT="${1:-$ROOT/docs/images}"
APP="$SCREENSHOT_BUILD/Codex Buddy Screenshots.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"
SOURCES=()
for source in "$ROOT"/Sources/*.swift; do [[ "$source" == */main.swift ]] || SOURCES+=("$source");done
swiftc -module-cache-path "$SCREENSHOT_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
 -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
 "${SOURCES[@]}" "$ROOT/scripts/ui-previews/main.swift" -o "$APP/Contents/MacOS/Screenshots"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/BuddyHead.png" "$APP/Contents/Resources/"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.duoduocat.codexbuddy.screenshots' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Screenshots' "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/Screenshots" --output "$OUT/overview-zh.png" --dark -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
"$APP/Contents/MacOS/Screenshots" --output "$OUT/overview-en.png" -AppleLanguages '(en)' -AppleLocale en_US
"$APP/Contents/MacOS/Screenshots" --output "$OUT/themes.png" --themes --dark -AppleLanguages '(en)' -AppleLocale en_US
"$APP/Contents/MacOS/Screenshots" --output "$OUT/settings-zh.png" --settings --dark -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
"$APP/Contents/MacOS/Screenshots" --output "$OUT/settings-en.png" --settings -AppleLanguages '(en)' -AppleLocale en_US
