#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="${TEST_BUILD_DIR:-$(mktemp -d /private/tmp/codex-buddy-tests.XXXXXX)}"
mkdir -p "$TEST_BUILD"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Sources/UpdatePolicy.swift" "$ROOT/Tests/main.swift" -o "$TEST_BUILD/tests"
"$TEST_BUILD/tests"
python3 "$ROOT/scripts/check-source.py"
python3 "$ROOT/scripts/test-installer.py"
python3 "$ROOT/scripts/test-privacy.py"
python3 "$ROOT/scripts/test-release-policy.py"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Tests/NetworkTests.swift" -o "$TEST_BUILD/network-tests"
"$TEST_BUILD/network-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -framework AppKit \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/UpdatePolicy.swift" "$ROOT/Sources/UpdateInstaller.swift" "$ROOT/Sources/Updates.swift" "$ROOT/Tests/UpdateManagerTests.swift" -o "$TEST_BUILD/update-tests"
"$TEST_BUILD/update-tests"
