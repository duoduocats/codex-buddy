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
    @Published var showResetDetails: Bool {
        didSet {
            preferences.set(showResetDetails,forKey:"showResetDetails")
            if showResetDetails && panelVisible { refreshResetCredits() }
            else if !showResetDetails { cancelResetCreditRequest() }
        }
    }
    @Published var resetDetailsOnlySoonest: Bool {
        didSet { preferences.set(resetDetailsOnlySoonest,forKey:"resetDetailsOnlySoonest") }
    }
    @Published var resetExpiryWindowDays: Int {
        didSet { preferences.set(resetExpiryWindowDays,forKey:"resetExpiryWindowDays") }
    }
    @Published var resetCreditDetails: ResetCreditDetails?
    @Published var resetCreditsRefreshing = false
    @Published var resetCreditsError: String?
    @Published var statistics: UsageStatistics?
    @Published var statisticsUpdated: Date?
    @Published var statisticsError: String?
    @Published var statisticsRefreshing = false
    let client: UsageClient
    let reminders: ResetReminderManager
    let challenge: TiboChallengeManager
    private let preferences: UserDefaults
    private var reminderSubscription: AnyCancellable?
    private var challengeSubscription: AnyCancellable?
    private var messageReceptionSubscription: AnyCancellable?
    private var environmentSubscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    private var failures = 0
    private var statisticsLastAttempt = Date.distantPast
    private var statisticsFailures = 0
    private var resetCreditsLastAttempt = Date.distantPast
    private var resetCreditsFailures = 0
    private var resetCreditsGeneration = 0
    private var resetCreditsTask: Task<Void,Never>?
    private var panelVisible = false
    private var demonstration = false
    init(preferences: UserDefaults = .standard, client: UsageClient? = nil,
         environmentNotifications: NotificationCenter = .default) {
        self.preferences = preferences
        self.client = client ?? UsageClient()
        self.reminders = ResetReminderManager(preferences:preferences)
        self.challenge = TiboChallengeManager(preferences:preferences,enabled:self.reminders.acceptsActivityMessages)
        self.menuBarTheme = (preferences.object(forKey:"menuBarTheme") as? String).flatMap(MenuBarTheme.init(rawValue:)) ?? .duoDuoCat
        self.menuShowsPercentage = preferences.bool(forKey:"menuShowsPercentage")
        self.showDailyTokenUsage = preferences.object(forKey:"showDailyTokenUsage") as? Bool ?? true
        self.showUsageShareButton = preferences.object(forKey:"showUsageShareButton") as? Bool ?? true
        self.showResetDetails = preferences.bool(forKey:"showResetDetails")
        self.resetDetailsOnlySoonest = preferences.bool(forKey:"resetDetailsOnlySoonest")
        let savedExpiryDays = preferences.object(forKey:"resetExpiryWindowDays") as? Int ?? 7
        self.resetExpiryWindowDays = [1,3,7,14,30].contains(savedExpiryDays) ? savedExpiryDays : 7
        reminderSubscription = reminders.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        challengeSubscription = challenge.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        messageReceptionSubscription = reminders.$messagesEnabled.combineLatest(reminders.$activityMessagesEnabled)
            .sink { [weak self] messages, activities in self?.challenge.setEnabled(messages && activities) }
        challenge.$document.sink { [weak self] document in
            self?.reminders.setActivityMessages(document.activityMessages)
        }.store(in:&environmentSubscriptions)
        for name in [Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            environmentNotifications.publisher(for:name).receive(on:DispatchQueue.main).sink { [weak self] _ in
                // Refresh visible dates when macOS changes its time zone or regional format.
                // This invalidates the panel without making another network request.
                self?.now = Date();self?.challenge.refreshClock()
            }.store(in:&environmentSubscriptions)
        }
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
        if demo { useDemo() } else { refresh(includeStatistics:false);reminders.start();challenge.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                if !demo { self.reminders.tick(now:self.now);self.challenge.tick() }
                if !demo, self.now.timeIntervalSince(self.lastAttempt) >= RefreshPolicy.interval(failures:self.failures) { self.refresh(includeStatistics:false) }
                if !demo, self.panelVisible { self.refreshStatistics();self.refreshResetCredits() }
            }
        }
        timer?.tolerance = 5
    }
    func refresh(includeStatistics: Bool = true) {
        if includeStatistics && panelVisible { refreshStatistics(force:true) }
        if includeStatistics && panelVisible { refreshResetCredits(force:true) }
        guard !demonstration else { return }
        guard !refreshing else { return }
        lastAttempt = Date()
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                let result = try await client.read()
                let countChanged = result.rateLimitResetCredits?.availableCount != credits
                if usage != result { usage = result }
                updated = Date(); now = Date(); error = nil; failures = 0
                if selection >= entries.count { selection = 0 }
                if panelVisible { refreshResetCredits(force:countChanged) }
            } catch {
                failures = min(failures + 1, 4)
                self.error = error.localizedDescription
            }
        }
    }
    func useDemo() {
        demonstration = true
        cancelResetCreditRequest()
        now = Date();usage = .demo;statistics = .demo(now:now);updated = now;statisticsUpdated = now
        resetCreditDetails = .demo(now:now,count:credits ?? 2);resetCreditsError = nil
        reminders.useDemo(now:now);challenge.useDemo()
    }
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { refreshStatistics();refreshResetCredits() }
        else { cancelResetCreditRequest() }
    }
    private func cancelResetCreditRequest() {
        if resetCreditsTask != nil { resetCreditsLastAttempt = .distantPast }
        resetCreditsGeneration += 1;resetCreditsTask?.cancel();resetCreditsTask = nil;resetCreditsRefreshing = false
    }
    private func refreshResetCredits(force:Bool = false) {
        guard showResetDetails, panelVisible, !demonstration, !resetCreditsRefreshing,
              UsageStatistics.shouldRefresh(now:Date(),lastAttempt:resetCreditsLastAttempt,failures:resetCreditsFailures,force:force) else { return }
        resetCreditsLastAttempt = Date()
        if credits == 0 && !stale {
            resetCreditDetails = .init(availableCount:0,credits:[]);resetCreditsError = nil;return
        }
        resetCreditsRefreshing = true;resetCreditsGeneration += 1
        let ticket = resetCreditsGeneration
        resetCreditsTask = Task {
            defer {
                if ticket == resetCreditsGeneration { resetCreditsRefreshing = false;resetCreditsTask = nil }
            }
            do {
                let value = try await client.readResetCredits()
                try Task.checkCancellation()
                guard ticket == resetCreditsGeneration, showResetDetails, panelVisible, !demonstration else { return }
                resetCreditDetails = value;resetCreditsError = nil;resetCreditsFailures = 0
            } catch is CancellationError { }
            catch {
                guard ticket == resetCreditsGeneration, !Task.isCancelled else { return }
                resetCreditsFailures = min(resetCreditsFailures+1,4)
                resetCreditsError = L("重置明细暂未更新，请稍后刷新。", "Reset details could not be updated. Try refreshing later.")
            }
        }
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
    @Published var enabled: Bool
    @Published var message: String?
    private let preview: Bool
    init(preview: Bool = false) {
        self.preview = preview
        enabled = preview ? false : SMAppService.mainApp.status == .enabled
    }
    func set(_ value: Bool) {
        if preview { enabled = value;return }
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            enabled = SMAppService.mainApp.status == .enabled
            message = SMAppService.mainApp.status == .requiresApproval ? L("请在系统设置 → 通用 → 登录项中允许启动。", "Allow launch at login in System Settings → General → Login Items.") : nil
        } catch { message = L("无法更新开机启动：\(error.localizedDescription)", "Could not change launch at login: \(error.localizedDescription)") }
    }
}
