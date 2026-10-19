#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="${TEST_BUILD_DIR:-$(mktemp -d /private/tmp/codex-buddy-tests.XXXXXX)}"
mkdir -p "$TEST_BUILD"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/BuddyNavigationMotion.swift" "$ROOT/Tests/BuddyNavigationMotionTests.swift" -o "$TEST_BUILD/navigation-motion-tests"
"$TEST_BUILD/navigation-motion-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Sources/UpdatePolicy.swift" "$ROOT/Tests/main.swift" -o "$TEST_BUILD/tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Sources/UsageTrends.swift" "$ROOT/Tests/UsageTrendsTests.swift" -o "$TEST_BUILD/usage-trends-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Sources/UsageForecast.swift" "$ROOT/Tests/UsageForecastTests.swift" -o "$TEST_BUILD/usage-forecast-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Sources/UsageForecast.swift" "$ROOT/Sources/ResetAnnouncements.swift" "$ROOT/Sources/UsageForecastResearch.swift" "$ROOT/Tests/UsageForecastResearchTests.swift" -o "$TEST_BUILD/forecast-research-tests"
"$TEST_BUILD/forecast-research-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/ResetAnnouncements.swift" "$ROOT/Tests/ResetAnnouncementTests.swift" -o "$TEST_BUILD/announcement-decoder-tests"
"$TEST_BUILD/announcement-decoder-tests"
"$TEST_BUILD/usage-forecast-tests"
"$TEST_BUILD/usage-trends-tests"
"$TEST_BUILD/tests"
python3 "$ROOT/scripts/check-source.py"
python3 "$ROOT/scripts/test-installer.py"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/UpdateHealth.swift" "$ROOT/Tests/UpdateHealthTests.swift" -o "$TEST_BUILD/update-health-tests"
"$TEST_BUILD/update-health-tests"
python3 "$ROOT/scripts/test-privacy.py"
python3 "$ROOT/scripts/test-pdf-privacy.py"
python3 "$ROOT/scripts/test-release-policy.py"
python3 "$ROOT/scripts/test-ci-verification.py"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Tests/NetworkTests.swift" -o "$TEST_BUILD/network-tests"
"$TEST_BUILD/network-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Tests/StatisticsTests.swift" -o "$TEST_BUILD/statistics-tests"
"$TEST_BUILD/statistics-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -framework AppKit -framework ServiceManagement -framework UserNotifications \
  "$ROOT/Sources/RefreshPolicy.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/MenuBarTheme.swift" "$ROOT/Sources/Statistics.swift" "$ROOT/Sources/Usage.swift" "$ROOT/Sources/UsageForecast.swift" "$ROOT/Sources/UsageForecastResearch.swift" "$ROOT/Sources/ResetAnnouncements.swift" "$ROOT/Sources/ResetReminders.swift" "$ROOT/Sources/TiboChallenge.swift" "$ROOT/Sources/Model.swift" "$ROOT/Tests/ModelTests.swift" -o "$TEST_BUILD/model-tests"
"$TEST_BUILD/model-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -framework AppKit -framework UserNotifications \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/ResetAnnouncements.swift" "$ROOT/Sources/ResetReminders.swift" "$ROOT/Tests/ResetReminderTests.swift" -o "$TEST_BUILD/reset-tests"
"$TEST_BUILD/reset-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -framework AppKit \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/MenuBarTheme.swift" "$ROOT/Sources/DuoDuoCatGeometry.swift" "$ROOT/Sources/MenuIconLayout.swift" "$ROOT/Tests/GeometryTests.swift" -o "$TEST_BUILD/geometry-tests"
"$TEST_BUILD/geometry-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -target arm64-apple-macosx13.0 -framework AppKit \
  "$ROOT/Sources/QuotaPanel.swift" "$ROOT/Tests/PanelTests.swift" -o "$TEST_BUILD/panel-tests"
"$TEST_BUILD/panel-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -framework AppKit \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/UpdatePolicy.swift" "$ROOT/Sources/UpdateInstaller.swift" "$ROOT/Sources/Updates.swift" "$ROOT/Tests/UpdateManagerTests.swift" -o "$TEST_BUILD/update-tests"
"$TEST_BUILD/update-tests"
SHARE_SOURCES=()
for file in "$ROOT"/Sources/*.swift "$ROOT"/Sources/Pets/*.swift; do
  [[ "$file" == */main.swift ]] || SHARE_SOURCES+=("$file")
done
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/SettingsServicesTests.swift" -o "$TEST_BUILD/settings-services-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/PetCloudLibraryTests.swift" -o "$TEST_BUILD/cloud-pet-tests"
"$TEST_BUILD/cloud-pet-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/ApplicationStorageTests.swift" -o "$TEST_BUILD/application-storage-tests"
"$TEST_BUILD/application-storage-tests"
"$TEST_BUILD/settings-services-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/UsageTrendsPresentationTests.swift" -o "$TEST_BUILD/trend-presentation-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/UsageForecastPresentationTests.swift" -o "$TEST_BUILD/forecast-presentation-tests"
"$TEST_BUILD/forecast-presentation-tests"
"$TEST_BUILD/trend-presentation-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/ShareTests.swift" -o "$TEST_BUILD/share-tests"
"$TEST_BUILD/share-tests" "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/BuddyMark.png"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/PanelLayoutTests.swift" -o "$TEST_BUILD/panel-layout-tests"
"$TEST_BUILD/panel-layout-tests"
swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/OverviewTests.swift" -o "$TEST_BUILD/overview-tests"
"$TEST_BUILD/overview-tests"

swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 \
  "$ROOT/Sources/Localization.swift" "$ROOT/Sources/ResetAnnouncements.swift" "$ROOT/Sources/TiboChallenge.swift" "$ROOT/Tests/ChallengeTests.swift" -o "$TEST_BUILD/challenge-tests"
"$TEST_BUILD/challenge-tests"
bash "$ROOT/scripts/validate-feeds.sh"
python3 "$ROOT/scripts/test-feed-publisher.py"

swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -target arm64-apple-macosx13.0 -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT"/Tests/Pets/*.swift -o "$TEST_BUILD/pet-store-tests"
"$TEST_BUILD/pet-store-tests"

swiftc -module-cache-path "$TEST_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement -framework UserNotifications \
  "${SHARE_SOURCES[@]}" "$ROOT/Tests/PetTagNetworkTests.swift" -o "$TEST_BUILD/tag-network-tests"
"$TEST_BUILD/tag-network-tests" "$ROOT/Tests/Pets/tag-binding-vectors.json"
