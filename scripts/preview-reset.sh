#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_BUILD="${PREVIEW_BUILD_DIR:-$(mktemp -d /private/tmp/buddy-reset-preview.XXXXXX)}"
OUT="${1:-$ROOT/preview-output}"
# Build and run outside cloud-managed folders, which can add FinderInfo after signing.
APP="$PREVIEW_BUILD/Codex Buddy Preview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PREVIEW_BUILD" "$OUT"
if [[ "${PREVIEW_SKIP_BUILD:-0}" != 1 ]]; then
SOURCES=()
for source in "$ROOT"/Sources/*.swift; do [[ "$source" == */main.swift ]] || SOURCES+=("$source");done
swiftc -module-cache-path "$PREVIEW_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
 -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
 "${SOURCES[@]}" "$ROOT/scripts/reset-previews/main.swift" -o "$APP/Contents/MacOS/Preview"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/BuddyHead.png" "$ROOT/Resources/BuddyMark.png" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.duoduocat.codexbuddy.preview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Codex Buddy Preview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Codex Buddy Preview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Preview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$APP/Contents/Info.plist"
xattr -cr "$APP"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
else
 [[ -x "$APP/Contents/MacOS/Preview" ]] || { printf 'Build the preview first.\n' >&2;exit 1; }
fi
codesign --verify --strict "$APP"
ditto --norsrc --noextattr -c -k --keepParent "$APP" "$OUT/Codex-Buddy-2.1.0-Preview.zip"
if [[ "${PREVIEW_SCREENSHOTS:-1}" == 1 ]]; then
 for language in zh en; do
  if [[ "$language" == zh ]];then LANGUAGES='(zh-Hans)';LOCALE=zh_CN;else LANGUAGES='(en)';LOCALE=en_US;fi
  for appearance in light dark; do
   APPEARANCE=(--light);[[ "$appearance" == dark ]] && APPEARANCE=(--dark)
   # Remove only obsolete synthetic states from earlier iterations of this preview.
   rm -f "$OUT/$language-$appearance-reset-completed.png" "$OUT/$language-$appearance-reset-cancelled.png" \
     "$OUT/$language-$appearance-reset-none.png" "$OUT/$language-$appearance-reminders-enabled.png"
   for scenario in ready downloading failure; do
    "$APP/Contents/MacOS/Preview" --output "$OUT/$language-$appearance-$scenario.png" --update "$scenario" "${APPEARANCE[@]}" -AppleLanguages "$LANGUAGES" -AppleLocale "$LOCALE"
   done
   "$APP/Contents/MacOS/Preview" --output "$OUT/$language-$appearance-message-none.png" --message none "${APPEARANCE[@]}" -AppleLanguages "$LANGUAGES" -AppleLocale "$LOCALE"
   "$APP/Contents/MacOS/Preview" --output "$OUT/$language-$appearance-notifications.png" --notifications "${APPEARANCE[@]}" -AppleLanguages "$LANGUAGES" -AppleLocale "$LOCALE"
  done
 done
fi
printf 'Interactive preview: %s\n' "$APP"
printf 'Preview archive: %s\n' "$OUT/Codex-Buddy-2.1.0-Preview.zip"
