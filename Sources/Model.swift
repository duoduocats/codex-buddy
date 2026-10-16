import AppKit
import Combine
import ServiceManagement
import CryptoKit

extension Notification.Name {
    static let buddyUsageForecastCacheCleared = Notification.Name("com.duoduocat.codexbuddy.forecast-cache-cleared")
}

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
    @Published var forecastObservations: [UsageForecastObservation] = []
    @Published var forecastUpdated: Date?
    @Published var forecastIdentity: String?
    @Published var forecastEvaluations: [UsageForecastEvaluationRecord] = []
    @Published var demoForecastExtraDate: Date? {
        didSet {
            if let date=demoForecastExtraDate, !demonstration || !date.timeIntervalSince1970.isFinite {
                demoForecastExtraDate = nil
            }
        }
    }
    private let forecastCache: UsageForecastCache?
    private let forecastEvaluationStore: UsageForecastEvaluationStore?
    private var forecastEvaluationDeactivation: Task<Void,Never>?
    private static let forecastModelVersion = "recent-linear-v2"
    private let forecastIdentitySalt: Data
    private var forecastGeneration = 0
    private var accountGeneration = 0
    private var quotaAccountRefreshPending = false
    private var statisticsAccountRefreshPending = false
    private var resetCreditsAccountRefreshPending = false
    private enum AccountRead { case quota, statistics, resetCredits }
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
    private var usageTrendsVisible = false
    private var mainWindowVisible = true
    private var demonstration = false
    var isDemonstrating: Bool { demonstration }
    private var statisticsVisible: Bool {
        (showDailyTokenUsage && panelVisible) || (usageTrendsVisible && mainWindowVisible)
    }
    init(preferences: UserDefaults = .standard, client: UsageClient? = nil,
         environmentNotifications: NotificationCenter = .default, forecastCache: UsageForecastCache? = nil,
         forecastEvaluationStore: UsageForecastEvaluationStore? = nil) {
        self.preferences = preferences
        self.forecastCache = forecastCache
        self.forecastEvaluationStore = forecastEvaluationStore
        if let saved = preferences.object(forKey:"forecast.localSalt") as? Data, saved.count == 32 {
            forecastIdentitySalt = saved
        } else {
            let salt = SymmetricKey(size:.bits256).withUnsafeBytes { Data($0) }
            forecastIdentitySalt = salt
            preferences.set(salt,forKey:"forecast.localSalt")
        }
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
        environmentNotifications.publisher(for:.buddyUsageForecastCacheCleared).receive(on:DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.forecastGeneration += 1
                self.forecastObservations = []
                self.forecastEvaluations = []
                self.deactivateForecastEvaluations()
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
                if !demo { self.refreshStatistics() }
                if !demo, self.panelVisible { self.refreshResetCredits() }
            }
        }
        timer?.tolerance = 5
    }
    func refresh(includeStatistics: Bool = true) {
        if includeStatistics { refreshStatistics(force:true) }
        if includeStatistics && panelVisible { refreshResetCredits(force:true) }
        guard !demonstration, !refreshing else { return }
        let attempted=Date(), accountTicket=accountGeneration
        lastAttempt=attempted;refreshing=true;quotaAccountRefreshPending=false
        Task {
            defer { refreshing=false;refillAccountData() }
            guard !demonstration, accountTicket == accountGeneration else { return }
            do {
                let generation=forecastGeneration
                let epoch=await forecastCache?.generationToken()
                // Capture the account and clear epoch before the existing RPC.
                // A first unknown identity deliberately skips one issuance;
                // completed old requests never reacquire a fresh session.
                await forecastEvaluationDeactivation?.value
                guard !demonstration, accountTicket == accountGeneration else { return }
                let evaluationSession=await forecastEvaluationStore?.session(accountKey:forecastIdentity,
                    accountGeneration:UInt64(accountTicket))
                guard !demonstration, accountTicket == accountGeneration else { return }
                let read=try await client.readForForecast(identitySalt:forecastIdentitySalt)
                guard acceptAccountContext(read.accountKey,requestedGeneration:accountTicket,source:.quota) else { return }
                let acceptedAccountGeneration=accountGeneration
                let result=read.response, fetched=Date()
                let countChanged=result.rateLimitResetCredits?.availableCount != credits
                if usage != result { usage=result }
                lastAttempt=attempted;updated=fetched;now=fetched;error=nil;failures=0
                forecastUpdated=fetched
                if generation == forecastGeneration {
                    if let forecastCache {
                        do {
                            let retained=try await forecastCache.record(usage:result,accountKey:read.accountKey,at:fetched,expectedGeneration:epoch)
                            if generation == forecastGeneration, acceptedAccountGeneration == accountGeneration, !demonstration {
                                forecastObservations=retained
                            }
                        } catch UsageForecastCacheFailure.staleGeneration {
                            // A cleared history must not be revived by an older request.
                        } catch {
                            if generation == forecastGeneration, acceptedAccountGeneration == accountGeneration, !demonstration {
                                let values=UsageForecastObservation.sanitized(usage:result,accountKey:read.accountKey,at:fetched)
                                forecastObservations=UsageForecastObservation.merged(existing:forecastObservations,incoming:values,at:fetched)
                            }
                        }
                    } else {
                        let values=UsageForecastObservation.sanitized(usage:result,accountKey:read.accountKey,at:fetched)
                        forecastObservations=UsageForecastObservation.merged(existing:forecastObservations,incoming:values,at:fetched)
                    }
                }
                guard acceptedAccountGeneration == accountGeneration, !demonstration else { return }
                if generation == forecastGeneration, let evaluationSession,
                   evaluationSession.accountKey == read.accountKey,
                   evaluationSession.accountGeneration == UInt64(acceptedAccountGeneration) {
                    await updateForecastEvaluations(result,session:evaluationSession,at:fetched,
                        generation:generation,accountTicket:acceptedAccountGeneration)
                }
                guard acceptedAccountGeneration == accountGeneration, !demonstration else { return }
                if selection >= entries.count { selection=0 }
                if panelVisible { refreshResetCredits(force:countChanged) }
                refillAccountData()
            } catch {
                guard !demonstration, accountTicket == accountGeneration else { return }
                failures=min(failures+1,4);self.error=error.localizedDescription
            }
        }
    }
    // Every successful endpoint carries the partition captured by its own
    // existing request. No second credential lookup can race the response.
    private func acceptAccountContext(_ key: String?,requestedGeneration: Int,source: AccountRead) -> Bool {
        guard !demonstration, requestedGeneration == accountGeneration else { return false }
        guard forecastIdentity != key else { return true }
        accountGeneration += 1;forecastIdentity=key
        usage=nil;updated=nil;error=nil;selection=0;lastAttempt = .distantPast;failures=0
        statistics=nil;statisticsUpdated=nil;statisticsError=nil;statisticsLastAttempt = .distantPast;statisticsFailures=0
        resetCreditDetails=nil;resetCreditsError=nil;resetCreditsLastAttempt = .distantPast;resetCreditsFailures=0
        forecastObservations=[];forecastUpdated=nil
        forecastEvaluations=[];deactivateForecastEvaluations()
        if source != .resetCredits { cancelResetCreditRequest() }
        quotaAccountRefreshPending=source != .quota
        statisticsAccountRefreshPending=source != .statistics
        resetCreditsAccountRefreshPending=source != .resetCredits
        return true
    }
    // Busy requests keep their single-flight slot until completion. Their defer
    // discards the old generation and fills currently visible data once.
    private func refillAccountData() {
        guard !demonstration else { return }
        if quotaAccountRefreshPending, !refreshing { refresh(includeStatistics:false) }
        if statisticsAccountRefreshPending, statisticsVisible, !statisticsRefreshing { refreshStatistics(force:true) }
        if resetCreditsAccountRefreshPending, showResetDetails, panelVisible, !resetCreditsRefreshing { refreshResetCredits(force:true) }
    }
    func useDemo() {
        demonstration = true;accountGeneration += 1
        quotaAccountRefreshPending=false;statisticsAccountRefreshPending=false;resetCreditsAccountRefreshPending=false
        forecastGeneration += 1;forecastIdentity = nil;forecastObservations = [];forecastUpdated = nil
        forecastEvaluations=[];demoForecastExtraDate=nil;deactivateForecastEvaluations()
        cancelResetCreditRequest()
        now = Date();usage = .demo;statistics = .demo(now:now);updated = now;statisticsUpdated = now
        forecastUpdated = now
        if let usage { forecastObservations = UsageForecastObservation.demo(usage:usage,now:now) }
        resetCreditDetails = .demo(now:now,count:credits ?? 2);resetCreditsError = nil
        reminders.useDemo(now:now);challenge.useDemo()
    }
    private func deactivateForecastEvaluations() {
        guard let forecastEvaluationStore else { return }
        let generation=UInt64(accountGeneration)
        let preceding=forecastEvaluationDeactivation
        forecastEvaluationDeactivation=Task {
            await preceding?.value
            await forecastEvaluationStore.deactivate(accountGeneration:generation)
        }
    }

    private func updateForecastEvaluations(_ usage: UsageResponse,session: UsageForecastEvaluationSession,at fetched: Date,
                                          generation: Int,accountTicket: Int) async {
        guard let forecastEvaluationStore else { return }
        func current() -> Bool {
            !demonstration && generation == forecastGeneration && accountTicket == accountGeneration
                && forecastIdentity == session.accountKey
        }
        guard current() else { return }
        do {
            // Evaluate prior immutable baseline inputs with later real reads.
            var records=try await forecastEvaluationStore.evaluate(observations:forecastObservations,session:session,at:fetched)
            guard current() else { return }
            let snapshot=UsageForecastSnapshot(usage:usage,observations:forecastObservations,updated:fetched,now:fetched)
            for window in snapshot.windows {
                guard current(), window.state == .ready,
                      let rate=window.observedPercentPerHour,rate.isFinite,rate > 0,
                      let target=window.exhaustionDate,let reset=window.resetDate,target > fetched,target < reset,
                      let input=window.observations.last,input.observedAt <= fetched,
                      fetched.timeIntervalSince(input.observedAt) <= UsageForecastEvaluator.maximumInputAge else { continue }
                // One issuance per quota cycle/model avoids making repeated
                // thirty-second reads look like independent accuracy samples.
                guard !records.contains(where: { $0.prediction.windowID == window.windowID
                    && $0.prediction.windowResetEpoch == reset && $0.prediction.modelVersion == Self.forecastModelVersion
                    && $0.prediction.windowDurationMins == input.windowDurationMins && $0.prediction.planType == input.planType
                    && $0.prediction.source == input.source && $0.prediction.segmentID == input.segmentID }) else { continue }
                let prediction=UsageForecastIssuedPrediction(windowID:window.windowID,issuedAt:fetched,
                    inputCutoff:input.observedAt,modelVersion:Self.forecastModelVersion,windowResetEpoch:reset,
                    predictedExhaustionAt:target,rate:rate,remaining:window.remainingPercent,
                    windowDurationMins:input.windowDurationMins,planType:input.planType,source:input.source,segmentID:input.segmentID)
                records=try await forecastEvaluationStore.record(prediction,session:session,at:fetched)
                guard current() else { return }
            }
            if current(), forecastEvaluations != records { forecastEvaluations=records }
        } catch {
            // Research persistence is optional and cannot fail the quota read.
            // In particular, stale clear/account sessions never publish a ledger.
        }
    }
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { refreshStatistics();refreshResetCredits() }
        else { cancelResetCreditRequest() }
    }
    func setUsageTrendsVisible(_ visible: Bool) {
        usageTrendsVisible = visible
        if visible { refreshStatistics() }
    }
    func setMainWindowVisible(_ visible: Bool) {
        mainWindowVisible = visible
        if visible && usageTrendsVisible { refreshStatistics() }
    }
    func refreshUsageTrends() {
        guard usageTrendsVisible, mainWindowVisible else { return }
        refreshStatistics(force:true)
    }
    private func cancelResetCreditRequest() {
        if resetCreditsTask != nil { resetCreditsLastAttempt = .distantPast }
        resetCreditsGeneration += 1;resetCreditsTask?.cancel();resetCreditsTask = nil;resetCreditsRefreshing = false
    }
    private func refreshResetCredits(force:Bool = false) {
        guard showResetDetails, panelVisible, !demonstration, !resetCreditsRefreshing,
              UsageStatistics.shouldRefresh(now:Date(),lastAttempt:resetCreditsLastAttempt,failures:resetCreditsFailures,force:force) else { return }
        let attempted=Date(), accountTicket=accountGeneration
        resetCreditsLastAttempt=attempted;resetCreditsAccountRefreshPending=false
        if credits == 0 && !stale {
            resetCreditDetails = .init(availableCount:0,credits:[]);resetCreditsError=nil;return
        }
        resetCreditsRefreshing=true;resetCreditsGeneration += 1
        let ticket=resetCreditsGeneration
        resetCreditsTask=Task {
            defer {
                if ticket == resetCreditsGeneration {
                    resetCreditsRefreshing=false;resetCreditsTask=nil;refillAccountData()
                }
            }
            guard !demonstration, accountTicket == accountGeneration else { return }
            do {
                let read=try await client.readResetCreditsWithContext(identitySalt:forecastIdentitySalt)
                try Task.checkCancellation()
                guard ticket == resetCreditsGeneration, showResetDetails, panelVisible,
                      acceptAccountContext(read.accountKey,requestedGeneration:accountTicket,source:.resetCredits) else { return }
                resetCreditDetails=read.response;resetCreditsLastAttempt=attempted;resetCreditsError=nil;resetCreditsFailures=0
                refillAccountData()
            } catch is CancellationError { }
            catch {
                guard ticket == resetCreditsGeneration, accountTicket == accountGeneration, !demonstration, !Task.isCancelled else { return }
                resetCreditsFailures=min(resetCreditsFailures+1,4)
                resetCreditsError=L("重置明细暂未更新，请稍后刷新。", "Reset details could not be updated. Try refreshing later.")
            }
        }
    }
    private func refreshStatistics(force: Bool = false) {
        guard statisticsVisible, !demonstration, !statisticsRefreshing,
              UsageStatistics.shouldRefresh(now:Date(),lastAttempt:statisticsLastAttempt,failures:statisticsFailures,force:force) else { return }
        let attempted=Date(), accountTicket=accountGeneration
        statisticsLastAttempt=attempted;statisticsRefreshing=true;statisticsAccountRefreshPending=false
        Task {
            defer { statisticsRefreshing=false;refillAccountData() }
            guard !demonstration, accountTicket == accountGeneration else { return }
            do {
                let read=try await client.readStatisticsWithContext(identitySalt:forecastIdentitySalt)
                guard acceptAccountContext(read.accountKey,requestedGeneration:accountTicket,source:.statistics) else { return }
                if statistics != read.response { statistics=read.response }
                statisticsLastAttempt=attempted;statisticsUpdated=Date();statisticsError=nil;statisticsFailures=0
                refillAccountData()
            } catch {
                guard !demonstration, accountTicket == accountGeneration else { return }
                statisticsFailures=min(statisticsFailures+1,4)
                statisticsError=L("用量统计暂不可用", "Usage statistics are unavailable")
            }
        }
    }

}

@MainActor protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() async throws
    func unregister() async throws
    func openSettings()
}

@MainActor struct SystemLoginItemService: LoginItemServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() async throws {
        try await Task.detached(priority:.userInitiated) { try SMAppService.mainApp.register() }.value
    }
    func unregister() async throws {
        try await Task.detached(priority:.userInitiated) { try SMAppService.mainApp.unregister() }.value
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor final class LoginModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var message: String?
    @Published private(set) var requiresApproval = false
    @Published private(set) var updating = false
    private let preview: Bool
    private let service: LoginItemServicing
    private var operation: Task<Void,Never>?
    init(preview: Bool = false,service: LoginItemServicing? = nil) {
        self.preview = preview;self.service = service ?? SystemLoginItemService()
        refresh()
    }
    func refresh() {
        guard !preview else { return }
        let status = service.status
        if enabled != (status == .enabled) { enabled = status == .enabled }
        if requiresApproval != (status == .requiresApproval) { requiresApproval = status == .requiresApproval }
        let next = requiresApproval
            ? L("请在系统登录项中允许开机启动。", "Allow launch at login in System Settings.")
            : status == .notFound ? L("请将应用放在“应用程序”中，再开启。", "Move the app to Applications before enabling it.") : nil
        if message != next { message = next }
    }
    func set(_ value: Bool) {
        guard !updating else { return }
        if preview { enabled = value;return }
        refresh()
        if value && requiresApproval { openSettings();return }
        guard value != enabled else { return }
        updating = true
        operation = Task {
            defer { updating = false;operation = nil }
            do {
                if value { try await service.register() } else { try await service.unregister() }
                refresh()
            } catch {
                refresh()
                // An external change may complete the requested state before this operation.
                if enabled != value && !requiresApproval {
                    message = L("无法更新开机启动，请重试或检查系统登录项。", "Could not change launch at login. Retry or check System Settings.")
                }
            }
        }
    }
    func openSettings() { guard !preview else { return };service.openSettings() }
    func finishUpdate() async { await operation?.value }
}
