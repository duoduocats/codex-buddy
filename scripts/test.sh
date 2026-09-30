#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="${TEST_BUILD_DIR:-$(mktemp -d /private/tmp/codex-buddy-tests.XXXXXX)}"
mkdir -p "$TEST_BUILD"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Sources/UpdatePolicy.swift" "$ROOT/Tests/main.swift" -o "$TEST_BUILD/tests"
"$TEST_BUILD/tests"
python3 "$ROOT/scripts/check-source.py"
python3 "$ROOT/scripts/test-installer.py"
python3 "$ROOT/scripts/test-privacy.py"
python3 "$ROOT/scripts/test-pdf-privacy.py"
python3 "$ROOT/scripts/test-release-policy.py"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Tests/NetworkTests.swift" -o "$TEST_BUILD/network-tests"
"$TEST_BUILD/network-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Tests/StatisticsTests.swift" -o "$TEST_BUILD/statistics-tests"
"$TEST_BUILD/statistics-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -framework AppKit -framework ServiceManagement \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/MenuBarTheme.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Sources/Model.swift" "$ROOT/Tests/ModelTests.swift" -o "$TEST_BUILD/model-tests"
"$TEST_BUILD/model-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -framework AppKit \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/MenuBarTheme.swift" "$ROOT/Sources/DuoDuoCatGeometry.swift" "$ROOT/Sources/MenuIconLayout.swift" "$ROOT/Tests/GeometryTests.swift" -o "$TEST_BUILD/geometry-tests"
"$TEST_BUILD/geometry-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -framework AppKit \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/UpdatePolicy.swift" "$ROOT/Sources/UpdateInstaller.swift" "$ROOT/Sources/Updates.swift" "$ROOT/Tests/UpdateManagerTests.swift" -o "$TEST_BUILD/update-tests"
"$TEST_BUILD/update-tests"
SHARE_SOURCES=()
for file in "$ROOT"/Sources/*.swift; do
  [[ "$file" == */main.swift ]] || SHARE_SOURCES+=("$file")
done
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/ShareTests.swift" -o "$TEST_BUILD/share-tests"
"$TEST_BUILD/share-tests"
