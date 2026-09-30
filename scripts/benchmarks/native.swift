import AppKit
import SwiftUI
import Combine
import Darwin

// Compiled only by benchmark-native.sh, with synthetic fixture data and a
// credential provider that always returns nil. Never part of the shipping app.
@MainActor enum PerformanceHarness {
    static weak var selection: ChartSelection?
    static let range = UsageChartRange()
}

@MainActor final class BenchmarkDelegate: NSObject, NSApplicationDelegate {
    struct Sample: Codable {
        var scenario: String
        var seconds: Double
        var averageCPUPercent: Double
        var cpuSeconds: Double
        var peakRSSMiB: Double
        var operations: Int
    }
    private let phases = ["idle_closed", "idle_panel", "hover_20hz", "range_switch_2hz", "panel_toggle_2hz"]
    private var samples = [Sample]()
    private var phase = 0
    private var operations = 0
    private var hoverIDs = [String]()
    private var snapshotIndex = 0
    private var tickTimer: Timer?
    private var cpuStart: clock_t = 0
    private var wallStart = 0.0
    private let suite = "com.duoduocat.codexbuddy.performance.\(ProcessInfo.processInfo.processIdentifier)"
    private var model: AppModel!
    private var item: NSStatusItem!
    private let panel = QuotaPanel()
    private var hosting: NSHostingController<UsageView>!
    private var subscription: AnyCancellable?
    private var statusKey = ""
    private var idleSeconds: Double { argument("--idle-seconds").flatMap(Double.init) ?? 60 }
    private var stressSeconds: Double { argument("--stress-seconds").flatMap(Double.init) ?? 30 }
    private func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of:name), index+1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index+1]
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let preferences = UserDefaults(suiteName:suite)!
        preferences.removePersistentDomain(forName:suite)
        model = AppModel(preferences:preferences,client:UsageClient(credentialProvider:{ nil }))
        model.menuBarTheme = .duoDuoCat
        model.start(demo:true)
        hoverIDs = model.statistics!.history(days:30,now:model.now).map(\.id)
        PerformanceHarness.range.days = 30
        item = NSStatusBar.system.statusItem(withLength:34)
        hosting = NSHostingController(rootView:UsageView(model:model,settings:{}))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.onClose = { [weak self] in self?.model.setPanelVisible(false) }
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }
        updateStatus()
        panel.contentSize = hosting.sizeThatFits(in:NSSize(width:380,height:1600))
        DispatchQueue.main.asyncAfter(deadline:.now()+3) {
            if let directory = self.argument("--snapshot-dir") {
                self.makeSnapshots(directory:directory)
            } else { self.beginPhase() }
        }
    }
    private func updateStatus() {
        let key = "\(model.window?.countdown(now:model.now) ?? "")|\(model.window?.remaining ?? 0)"
        guard key != statusKey else { return }
        statusKey = key
        item.button?.image = DuoDrawing.image(size:NSSize(width:30,height:24),window:model.window,credits:model.credits,now:model.now,menu:true,stale:false,dark:true,menuShowsPercentage:false,menuTheme:.duoDuoCat)
    }
    private func showPanel() {
        guard !panel.isShown else { return }
        guard let button = item.button else { return }
        model.setPanelVisible(true)
        panel.contentSize = hosting.sizeThatFits(in:NSSize(width:380,height:1600))
        panel.show(relativeTo:button.bounds,of:button,preferredEdge:.maxY)
        hosting.view.layoutSubtreeIfNeeded()
        hosting.view.displayIfNeeded()
    }
    private func beginPhase() {
        guard phase < phases.count else { finish();return }
        let scenario = phases[phase]
        if phase == 0 { panel.close() } else { showPanel() }
        PerformanceHarness.selection?.update(nil)
        operations = 0
        // Give native layout and animations a separate warm-up interval.
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [self] in
            self.cpuStart = clock();self.wallStart = ProcessInfo.processInfo.systemUptime
            if self.phase >= 2 {
                let interval = self.phase == 2 ? 0.05 : 0.5
                self.tickTimer = Timer.scheduledTimer(withTimeInterval:interval,repeats:true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stressTick() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+(self.phase < 2 ? self.idleSeconds : self.stressSeconds)) {
                self.tickTimer?.invalidate();self.tickTimer = nil
                let wall = ProcessInfo.processInfo.systemUptime-self.wallStart
                let cpu = Double(clock()-self.cpuStart)/Double(CLOCKS_PER_SEC)
                var usage = rusage();getrusage(RUSAGE_SELF,&usage)
                let result = Sample(scenario:scenario,seconds:wall,averageCPUPercent:100*cpu/wall,
                    cpuSeconds:cpu,peakRSSMiB:Double(usage.ru_maxrss)/1048576,operations:self.operations)
                self.samples.append(result)
                print(String(format:"%@ %.3f%% CPU over %.1fs, %.1f MiB peak RSS, %d operations",scenario,result.averageCPUPercent,wall,result.peakRSSMiB,result.operations))
                fflush(stdout)
                self.phase += 1;self.beginPhase()
            }
        }
    }
    private func stressTick() {
        operations += 1
        if phase == 2 {
            PerformanceHarness.selection?.update(hoverIDs[operations % hoverIDs.count])
        } else if phase == 3 {
            PerformanceHarness.range.days = [7,14,30][operations % 3]
        } else if panel.isShown { panel.close() } else { showPanel() }
        // Force native view work even if the desktop is locked/occluded.
        // This does not inject OS input events or access the user's data.
        hosting.view.layoutSubtreeIfNeeded();hosting.view.displayIfNeeded()
    }
    private func makeSnapshots(directory:String) {
        let cases = [(7,"left"),(7,"right"),(14,"left"),(14,"right"),(30,"left"),(30,"right")]
        guard snapshotIndex < cases.count else { finish();return }
        if snapshotIndex == 0 {
            let daily = model.statistics!.history(days:30,now:model.now).enumerated().map { index,row in
                DailyTokenUsage(day:row.day,tokens:index == 0 || index == 29 ? 123_456_789_012 : row.tokens)
            }
            model.statistics = UsageStatistics(lifetimeTokens:4_860_000_000,peakDailyTokens:123_456_789_012,
                longestRunningTurnSec:22_500,longestStreakDays:24,currentStreakDays:9,daily:daily)
            try! FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        }
        let (days,edge) = cases[snapshotIndex]
        PerformanceHarness.range.days = days
        showPanel()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
            let rows = self.model.statistics!.history(days:days,now:self.model.now)
            PerformanceHarness.selection?.update(edge == "left" ? rows.first!.id : rows.last!.id)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
                self.hosting.view.layoutSubtreeIfNeeded();self.hosting.view.displayIfNeeded()
                let view = self.hosting.view
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { fatalError("Native chart snapshot must allocate") }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let png = bitmap.representation(using:.png,properties:[:]) else { fatalError("Native snapshot must encode") }
                let file = URL(fileURLWithPath:directory).appendingPathComponent("hover-\(edge)-\(days)d.png")
                try! png.write(to:file,options:.atomic)
                self.snapshotIndex += 1;self.makeSnapshots(directory:directory)
            }
        }
    }
    private func finish() {
        panel.close();model.client.stop()
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
        if let path = argument("--output") {
            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try! encoder.encode(samples).write(to:URL(fileURLWithPath:path),options:.atomic)
        }
        NSApp.terminate(nil)
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = BenchmarkDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
