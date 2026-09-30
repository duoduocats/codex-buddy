#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_BUILD="${BENCHMARK_BUILD_DIR:-$(mktemp -d /private/tmp/codex-buddy-benchmark.XXXXXX)}"
APP="$BENCH_BUILD/Codex Buddy Benchmark.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Add a controlled fixture driver only in a temporary copy of the chart.
# The shipping chart has no benchmark hooks or automatic hover behavior.
python3 - "$ROOT" "$BENCH_BUILD" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
chart=(root/'Sources/UsageChart.swift').read_text()
chart=chart.replace('@MainActor private final class ChartSelection', '@MainActor final class ChartSelection', 1)
needle='    @Published var hovered: String?\n'
assert chart.count(needle)==1
chart=chart.replace(needle, needle+'    init() { PerformanceHarness.selection = self }\n', 1)
(build/'UsageChart.swift').write_text(chart)
views=(root/'Sources/Views.swift').read_text()
needle='    @StateObject private var chartRange = UsageChartRange()'
assert views.count(needle)==1
(build/'Views.swift').write_text(views.replace(needle,'    @ObservedObject private var chartRange = PerformanceHarness.range',1))
(build/'main.swift').write_bytes((root/'scripts/benchmarks/native.swift').read_bytes())
PY
SOURCES=()
for file in "$ROOT"/Sources/*.swift; do
  case "$file" in */main.swift|*/UsageChart.swift|*/Views.swift) ;; *) SOURCES+=("$file");; esac
done
swiftc -module-cache-path "$BENCH_BUILD/module-cache" -swift-version 5 -Osize -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement \
  "${SOURCES[@]}" "$BENCH_BUILD/UsageChart.swift" "$BENCH_BUILD/Views.swift" "$BENCH_BUILD/main.swift" \
  -o "$APP/Contents/MacOS/Benchmark"
cp "$ROOT/Resources/BuddyHead.png" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.duoduocat.codexbuddy.performance</string>
<key>CFBundleExecutable</key><string>Benchmark</string>
<key>CFBundleName</key><string>Codex Buddy Benchmark</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
if [[ "${1:-}" == "--build-only" ]]; then printf '%s\n' "$APP";exit 0;fi
"$APP/Contents/MacOS/Benchmark" "$@"
