#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUTPUT_DIR:-$ROOT/dist}"
RELEASE_BUILD="${BUILD_DIR:-$(mktemp -d /private/tmp/codex-buddy-release.XXXXXX)}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")
BUILD_DIR="$RELEASE_BUILD" bash "$ROOT/build.sh"
python3 "$ROOT/scripts/check-package.py" "$RELEASE_BUILD/Codex Buddy.app"
mkdir -p "$OUT"
STAGE=$(mktemp -d /private/tmp/codex-buddy-stage.XXXXXX)
MOUNT=$(mktemp -d /private/tmp/codex-buddy-volume.XXXXXX)
RW="$STAGE/installer-rw.dmg"
cleanup() {
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    rm -rf "$STAGE" "$MOUNT"
}
trap cleanup EXIT
# The stage is always a newly created temporary directory owned by this script.
CONTENTS="$STAGE/contents"
mkdir -p "$CONTENTS/.background"
ditto "$RELEASE_BUILD/Codex Buddy.app" "$CONTENTS/Codex Buddy.app"
ln -s /Applications "$CONTENTS/Applications"
cp "$ROOT/docs/install/Installation-Guide.pdf" "$CONTENTS/安装指南 Installation Guide.pdf"
cp "$ROOT/docs/install/dmg-background.png" "$CONTENTS/.background/install.png"
NAME="Codex-Buddy-$VERSION-arm64.dmg"
# Finder metadata needs file IDs from the actual volume, then survives conversion.
# ds_store/mac_alias are build-only tools from requirements-packaging.txt.
python3 -c 'import ds_store, mac_alias, pypdf' || {
    echo 'Install build-only tools: python3 -m pip install -r scripts/requirements-packaging.txt' >&2
    exit 1
}
hdiutil create -volname 'Codex Buddy' -srcfolder "$CONTENTS" -format UDRW -fs HFS+ -ov "$RW" -quiet
hdiutil attach "$RW" -mountpoint "$MOUNT" -nobrowse -noautoopen -quiet
python3 "$ROOT/scripts/configure-dmg.py" "$MOUNT"
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT/$NAME" -quiet
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
python3 "$ROOT/scripts/check-package.py" "$RELEASE_BUILD/Codex Buddy.app" --dmg "$OUT/$NAME"
echo "$OUT/$NAME"
