import AppKit
import Combine
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var updated: Date?
    @Published var error: String?
    @Published var refreshing = false
    @Published var now = Date()
    @Published var selection = 0
    @Published var menuBarTheme: MenuBarTheme {
        didSet { preferences.set(menuBarTheme.rawValue,forKey:"menuBarTheme") }
    }
    @Published var menuShowsPercentage: Bool {
        didSet { preferences.set(menuShowsPercentage,forKey:"menuShowsPercentage") }
    }
    @Published var showDailyTokenUsage: Bool {
        didSet {
            preferences.set(showDailyTokenUsage,forKey:"showDailyTokenUsage")
            if showDailyTokenUsage && panelVisible { refreshStatistics() }
        }
    }
    @Published var showUsageShareButton: Bool {
        didSet { preferences.set(showUsageShareButton,forKey:"showUsageShareButton") }
    }
    @Published var statistics: UsageStatistics?
    @Published var statisticsUpdated: Date?
    @Published var statisticsError: String?
    @Published var statisticsRefreshing = false
    let client: UsageClient
    private let preferences: UserDefaults
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    private var failures = 0
    private var statisticsLastAttempt = Date.distantPast
    private var statisticsFailures = 0
    private var panelVisible = false
    private var demonstration = false
    init(preferences: UserDefaults = .standard, client: UsageClient? = nil) {
        self.preferences = preferences
        self.client = client ?? UsageClient()
        self.menuBarTheme = (preferences.object(forKey:"menuBarTheme") as? String).flatMap(MenuBarTheme.init(rawValue:)) ?? .ring
        self.menuShowsPercentage = preferences.bool(forKey:"menuShowsPercentage")
        self.showDailyTokenUsage = preferences.object(forKey:"showDailyTokenUsage") as? Bool ?? true
        self.showUsageShareButton = preferences.object(forKey:"showUsageShareButton") as? Bool ?? true
    }
    var entries: [(String, LimitWindow)] {
        usage?.buckets.flatMap { key, bucket in
            bucket.windows.map { ((bucket.limitName ?? key) == "codex" ? $0.label : "\(bucket.limitName ?? key) · \($0.label)", $0) }
        } ?? []
    }
    var window: LimitWindow? { entries.indices.contains(selection) ? entries[selection].1 : entries.first?.1 }
    var credits: Int? { usage?.rateLimitResetCredits?.availableCount }
    var stale: Bool { error != nil || updated.map { now.timeIntervalSince($0) > 150 } == true }
    func start(demo: Bool = false) {
        guard timer == nil else { return }
        if demo { useDemo() } else { refresh(includeStatistics:false) }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                if !demo, self.now.timeIntervalSince(self.lastAttempt) >= RefreshPolicy.interval(failures:self.failures) { self.refresh(includeStatistics:false) }
                if !demo, self.panelVisible { self.refreshStatistics() }
            }
        }
        timer?.tolerance = 5
    }
    func refresh(includeStatistics: Bool = true) {
        if includeStatistics && panelVisible { refreshStatistics(force:true) }
        guard !demonstration else { return }
        guard !refreshing else { return }
        lastAttempt = Date()
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                let result = try await client.read()
                if usage != result { usage = result }
                updated = Date(); now = Date(); error = nil; failures = 0
                if selection >= entries.count { selection = 0 }
            } catch {
                failures = min(failures + 1, 4)
                self.error = error.localizedDescription
            }
        }
    }
    func useDemo() {
        demonstration = true
        now = Date();usage = .demo;statistics = .demo(now:now);updated = now;statisticsUpdated = now
    }
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { refreshStatistics() }
    }
    private func refreshStatistics(force: Bool = false) {
        guard showDailyTokenUsage, !demonstration, !statisticsRefreshing,
              UsageStatistics.shouldRefresh(now:Date(),lastAttempt:statisticsLastAttempt,failures:statisticsFailures,force:force) else { return }
        statisticsLastAttempt = Date();statisticsRefreshing = true
        Task {
            defer { statisticsRefreshing = false }
            do {
                let result = try await client.readStatistics()
                if statistics != result { statistics = result }
                statisticsUpdated = Date();statisticsError = nil;statisticsFailures = 0
            } catch {
                statisticsFailures = min(statisticsFailures+1,4)
                statisticsError = L("用量统计暂不可用", "Usage statistics are unavailable")
            }
        }
    }
}

@MainActor final class LoginModel: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var message: String?
    func set(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            enabled = SMAppService.mainApp.status == .enabled
            message = SMAppService.mainApp.status == .requiresApproval ? L("请在系统设置 → 通用 → 登录项中允许启动。", "Allow launch at login in System Settings → General → Login Items.") : nil
        } catch { message = L("无法更新开机启动：\(error.localizedDescription)", "Could not change launch at login: \(error.localizedDescription)") }
    }
}
