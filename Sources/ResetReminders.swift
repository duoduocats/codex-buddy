import AppKit
import Combine
import UserNotifications

enum ResetNotificationAuthorization { case notDetermined, allowed, denied }
struct ResetNotification {
    let identifier: String
    let title: String
    let body: String
    let deliveryDate: Date?
    let eventID: String
    let sourceURL: URL?
}
enum ResetNotificationAction { case openPanel }
@MainActor protocol ResetNotificationDelivering: AnyObject {
    func authorization() async -> ResetNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func schedule(_ notification: ResetNotification) async throws
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
    func removeAll()
    func setActionHandler(_ handler: @escaping (ResetNotificationAction) -> Void)
    func prepare()
}
extension ResetNotificationDelivering {
    func prepare() {}
    func setActionHandler(_ handler: @escaping (ResetNotificationAction) -> Void) {}
}
@MainActor private final class NativeResetNotifications: NSObject, ResetNotificationDelivering, UNUserNotificationCenterDelegate {
    static let prefix = "codex-buddy.reset."
    private var actionHandler: ((ResetNotificationAction) -> Void)?
    private var cleanup: Task<Void,Never>?
    // Never construct the native notification center in a CLI test or demo preview.
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current();center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier:"buddy.message",actions:[],intentIdentifiers:[],options:[])])
        return center
    }()
    func setActionHandler(_ handler: @escaping (ResetNotificationAction) -> Void) { actionHandler = handler }
    func prepare() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        _ = center
    }
    func authorization() async -> ResetNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options:[.alert]) }
    func schedule(_ notification: ResetNotification) async throws {
        if let cleanup { await cleanup.value }
        let content = UNMutableNotificationContent()
        content.title = notification.title;content.body = notification.body;content.categoryIdentifier = "buddy.message"
        content.userInfo = ["eventID":notification.eventID]
        try await center.add(UNNotificationRequest(identifier:notification.identifier,content:content,trigger:nil))
    }
    func removePending(identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers:identifiers) }
    func removeDelivered(identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers:identifiers) }
    func removeAll() {
        let previous = cleanup
        cleanup = Task {
            if let previous { await previous.value }
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            let delivered = await center.deliveredNotifications().map { $0.request.identifier }.filter { $0.hasPrefix(Self.prefix) }
            removePending(identifiers:pending);removeDelivered(identifiers:delivered)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner,.list])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == UNNotificationDefaultActionIdentifier { self.actionHandler?(.openPanel) }
            completionHandler()
        }
    }
}

@MainActor final class ResetReminderManager: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var messagesEnabled: Bool
    @Published private(set) var remindBefore: Bool
    @Published private(set) var upcoming: ResetAnnouncement?
    @Published private(set) var message: String?
    @Published private(set) var checking = false
    @Published private var panelDismissed: Set<String> = []
    var onOpenPanel: (() -> Void)?
    private let preferences: UserDefaults
    private let client: ResetAnnouncementFetching
    private let now: () -> Date
    private var notificationDependency: ResetNotificationDelivering?
    private var notifications: ResetNotificationDelivering {
        if let notificationDependency { return notificationDependency }
        let value = NativeResetNotifications();notificationDependency = value
        value.setActionHandler { [weak self] action in self?.handle(action) }
        return value
    }
    private var document: ResetAnnouncementDocument?
    private var etag: String?
    private var lastAttempt: Date?
    private var failures = 0
    private var announced: [String: Date]
    private var ignored: [String: Date]
    private var revisions: [String: Int]
    private var enabledAt: Date?
    private var started = false
    private var demo = false
    private var generation = 0
    private var checkGeneration = 0
    private var checkTask: Task<Void,Never>?
    private var notificationTask: Task<Void,Never>?
    static let preferencePrefix = "resetReminders."
    init(preferences: UserDefaults = .standard, client: ResetAnnouncementFetching? = nil,
         notifications: ResetNotificationDelivering? = nil, now: @escaping () -> Date = { Date() }) {
        self.preferences = preferences;self.client = client ?? ResetAnnouncementClient();self.now = now
        self.notificationDependency = notifications
        enabled = preferences.bool(forKey:Self.preferencePrefix+"enabled")
        messagesEnabled = preferences.object(forKey:Self.preferencePrefix+"messagesEnabled") as? Bool
            ?? preferences.object(forKey:Self.preferencePrefix+"panelMessagesEnabled") as? Bool ?? true
        // Compatibility property for earlier preview callers; message reminders have no timed stages.
        remindBefore = false
        enabledAt = preferences.object(forKey:Self.preferencePrefix+"enabledAt") as? Date
        announced = Self.readDates(preferences,key:"announced",limit:256)
        ignored = Self.readDates(preferences,key:"ignored",limit:100)
        revisions = (preferences.dictionary(forKey:Self.preferencePrefix+"revisions") as? [String:Int] ?? [:]).filter {
            ResetAnnouncementDocument.validID($0.key) && (1...1_000_000).contains($0.value)
        }
        if revisions.count > 50 { revisions = [:] }
        lastAttempt = preferences.object(forKey:Self.preferencePrefix+"lastAttempt") as? Date
        failures = min(5,max(0,preferences.integer(forKey:Self.preferencePrefix+"failures")))
        if let data = preferences.data(forKey:Self.preferencePrefix+"cache"), let value = try? ResetAnnouncementDocument.decode(data,now:now()) {
            document = value;etag = ResetAnnouncementClient.validETag(preferences.string(forKey:Self.preferencePrefix+"etag"))
        } else {
            preferences.removeObject(forKey:Self.preferencePrefix+"cache");preferences.removeObject(forKey:Self.preferencePrefix+"etag")
        }
        notifications?.setActionHandler { [weak self] action in self?.handle(action) }
        prune();selectUpcoming()
    }
    func start() {
        guard !started, !demo else { return };started = true
        guard messagesEnabled else { if enabled { cancelAll() };return }
        notifications.prepare();processNotifications();check()
    }
    func stop() { started = false;checkGeneration += 1;checkTask?.cancel();checkTask = nil;checking = false }
    func tick(now: Date) {
        guard !demo, messagesEnabled else { return }
        let previous = upcoming
        prune(at:now);selectUpcoming(at:now)
        if previous != upcoming { processNotifications(replace:true) }
        if started { check() }
    }
    func check(force: Bool = false) {
        guard !demo, messagesEnabled, !checking else { return }
        let timestamp = now()
        let interval = min(6*3_600.0,900*pow(2,Double(failures)))
        if let lastAttempt {
            let elapsed = timestamp.timeIntervalSince(lastAttempt)
            if elapsed < 0 { self.lastAttempt = nil }
            else if elapsed < ((force && failures == 0) ? 30 : interval) { return }
        }
        lastAttempt = timestamp;preferences.set(timestamp,forKey:Self.preferencePrefix+"lastAttempt");checking = true
        checkGeneration += 1;let checkTicket = checkGeneration
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer { if checkTicket == checkGeneration { self.checking = false;self.checkTask = nil } }
            do {
                let result = try await client.fetch(etag:etag)
                try Task.checkCancellation()
                guard checkTicket == checkGeneration, !demo, messagesEnabled else { throw CancellationError() }
                switch result {
                case .notModified:
                    guard document != nil else { throw ResetAnnouncementFailure.invalid }
                case let .document(data,newETag):
                    let value = try ResetAnnouncementDocument.decode(data,now:now())
                    // A stale feed must not replay older revisions or alter an event without a revision bump.
                    for event in value.events {
                        if let previous = document?.events.first(where:{ $0.id == event.id }) {
                            guard event.revision >= previous.revision,
                                  event.revision != previous.revision || event == previous else { throw ResetAnnouncementFailure.invalid }
                        }
                    }
                    document = value;etag = ResetAnnouncementClient.validETag(newETag)
                    preferences.set(data,forKey:Self.preferencePrefix+"cache")
                    preferences.set(etag,forKey:Self.preferencePrefix+"etag")
                }
                failures = 0;preferences.set(0,forKey:Self.preferencePrefix+"failures")
                if message != L("通知未获授权，请在系统设置中允许 Codex Buddy 通知。", "Notifications are not allowed. Enable Codex Buddy notifications in System Settings.") { message = nil }
                prune();selectUpcoming();processNotifications(replace:true)
            } catch is CancellationError { }
            catch {
                guard checkTicket == checkGeneration, !Task.isCancelled else { return }
                failures = min(5,failures+1);preferences.set(failures,forKey:Self.preferencePrefix+"failures")
                if force { message = L("消息检查失败，将稍后重试。", "Could not check messages. Will retry later.") }
            }
        }
    }
    func setMessagesEnabled(_ value: Bool) {
        guard value != messagesEnabled else { return }
        messagesEnabled = value
        guard !demo else { return }
        preferences.set(value,forKey:Self.preferencePrefix+"messagesEnabled")
        if !value {
            checkGeneration += 1;checkTask?.cancel();checkTask = nil;checking = false
            generation += 1;notificationTask?.cancel()
            upcoming = nil;message = nil
            if enabled || notificationDependency != nil { cancelAll() }
        } else {
            lastAttempt = nil;failures = 0
            preferences.removeObject(forKey:Self.preferencePrefix+"lastAttempt")
            preferences.set(0,forKey:Self.preferencePrefix+"failures")
            prune();selectUpcoming()
            if enabled {
                enabledAt = now();preferences.set(enabledAt,forKey:Self.preferencePrefix+"enabledAt")
            }
            if started { notifications.prepare();processNotifications(replace:true);check() }
        }
    }
    func setEnabled(_ value: Bool) {
        guard !value || messagesEnabled else { return }
        guard !demo else { enabled = value;return }
        generation += 1
        if !value {
            enabled = false;preferences.set(false,forKey:Self.preferencePrefix+"enabled")
            notificationTask?.cancel();cancelAll();return
        }
        let ticket = generation
        let previous = notificationTask
        previous?.cancel()
        notificationTask = Task { [weak self] in
            if let previous { await previous.value }
            guard let self, ticket == self.generation, !Task.isCancelled else { return }
            do {
                let authorization = await notifications.authorization()
                var allowed = authorization == .allowed
                if authorization == .notDetermined { allowed = try await notifications.requestAuthorization() }
                guard ticket == generation, messagesEnabled, !Task.isCancelled else { return }
                guard allowed else {
                    enabled = false;preferences.set(false,forKey:Self.preferencePrefix+"enabled")
                    message = L("通知未获授权，请在系统设置中允许 Codex Buddy 通知。", "Notifications are not allowed. Enable Codex Buddy notifications in System Settings.")
                    notificationTask = nil;return
                }
                enabled = true;enabledAt = now();preferences.set(true,forKey:Self.preferencePrefix+"enabled")
                preferences.set(enabledAt,forKey:Self.preferencePrefix+"enabledAt");message = nil
                notificationTask = nil;processNotifications();check(force:true)
            } catch {
                guard ticket == generation else { return }
                enabled = false;preferences.set(false,forKey:Self.preferencePrefix+"enabled")
                message = L("无法开启通知，请稍后重试。", "Could not enable notifications. Try again later.")
                notificationTask = nil
            }
        }
    }
    func setRemindBefore(_ value: Bool) {
        // Kept as a no-op for source compatibility; no advance/deadline notifications are scheduled.
    }
    func openSource() {
        guard !demo, let url = upcoming?.sourceURL, ResetAnnouncementDocument.validSourceURL(url) else { return }
        NSWorkspace.shared.open(url)
    }
    func panelAnnouncement(at timestamp: Date) -> ResetAnnouncement? {
        guard messagesEnabled, let event = upcoming, !panelDismissed.contains(event.id),
              event.publishedAt <= timestamp, event.expiresAt > timestamp else { return nil }
        if let deadline = event.scheduledAt, (event.type == "message" || event.status == .scheduled), deadline <= timestamp { return nil }
        return event
    }
    func dismissPanelAnnouncement() {
        guard let event = upcoming else { return }
        panelDismissed.insert(event.id)
    }
    func ignoreUpcoming() {
        if demo { upcoming = nil;return }
        if let event = upcoming { ignore(event.id) }
    }
    func useDemo(now: Date, status: ResetAnnouncementStatus? = .scheduled) {
        // Called before start in previews; no network, notification or preference mutations.
        demo = true;started = false;checkGeneration += 1;checkTask?.cancel();checkTask = nil;checking = false
        notificationTask?.cancel();notificationTask = nil;generation += 1
        panelDismissed = []
        guard let status else { upcoming = nil;message = nil;return }
        upcoming = ResetAnnouncement(id:"demo-global-reset",revision:1,type:"message",status:status,
            scheduledAt:now.addingTimeInterval(3_600),publishedAt:now,expiresAt:now.addingTimeInterval(86_400),
            titleText:.init(zh:"全球重置",en:"Global reset"),
            bodyText:.init(zh:"演示消息：所有付费 ChatGPT 账户预计将获得额度重置，时间以官方公告为准。",en:"Sample message: a quota reset is expected for paid ChatGPT accounts. The timing is subject to the official announcement."))
        message = nil
    }
    private func selectUpcoming(at timestamp: Date? = nil) {
        guard messagesEnabled else { upcoming = nil;return }
        let time = timestamp ?? now()
        let selected = document?.events.filter {
            self.isActive($0,at:time) && self.ignored[$0.id] == nil
        }.sorted { $0.publishedAt > $1.publishedAt }.first
        if upcoming != selected { upcoming = selected }
    }
    private func processNotifications(replace: Bool = false) {
        guard messagesEnabled, enabled, !demo else { return }
        guard replace || notificationTask == nil else { return }
        if replace { generation += 1 }
        let previous = notificationTask
        previous?.cancel()
        let ticket = generation
        notificationTask = Task { [weak self] in
            if let previous { await previous.value }
            guard let self, ticket == self.generation, !Task.isCancelled else { return }
            defer { if ticket == generation { notificationTask = nil } }
            guard await notifications.authorization() == .allowed else {
                if ticket == generation { enabled = false;preferences.set(false,forKey:Self.preferencePrefix+"enabled");cancelAll() }
                return
            }
            guard ticket == generation, enabled, !Task.isCancelled else { return }
            let time = now()
            let liveIDs = Set((document?.events ?? []).filter { self.isActive($0,at:time) }.map(\.id))
            for id in revisions.keys where !liveIDs.contains(id) {
                let ids = ["announce","before","time","completed","cancelled"].map { self.identifier(id,$0) }
                notifications.removePending(identifiers:ids);notifications.removeDelivered(identifiers:ids);revisions.removeValue(forKey:id)
            }
            let knownIDs = Set(announced.keys.compactMap { $0.split(separator:"|").first.map(String.init) })
            for event in document?.events ?? [] {
                // Remove the timed requests used by earlier previews; messages have one immediate banner.
                notifications.removePending(identifiers:[identifier(event.id,"before"),identifier(event.id,"time")])
                revisions[event.id] = event.revision
            }
            let active = (document?.events ?? []).filter {
                self.isActive($0,at:time) && self.ignored[$0.id] == nil
            }
            for event in active {
                guard ticket == generation, enabled, !Task.isCancelled else { return }
                if event.id == upcoming?.id || event.publishedAt >= (enabledAt ?? time) || knownIDs.contains(event.id) {
                    // Enabling notifications shows the current message, without replaying unrelated older messages.
                    try? await deliver(event,phase:"announce",title:event.title,
                                       body:[event.body,event.timeDescription()].joined(separator:"\n"),date:nil,ticket:ticket)
                }
            }
            guard ticket == generation, enabled, !Task.isCancelled else { return }
            persistRecords()
        }
    }
    private func isActive(_ event: ResetAnnouncement, at timestamp: Date) -> Bool {
        guard event.publishedAt <= timestamp, event.expiresAt > timestamp else { return false }
        if let deadline = event.scheduledAt, (event.type == "message" || event.status == .scheduled) { return deadline > timestamp }
        return true
    }
    private func deliver(_ event: ResetAnnouncement, phase: String, title: String, body: String, date: Date?, ticket: Int) async throws {
        let record = key(event,phase), id = identifier(event.id,phase)
        guard ticket == generation, messagesEnabled, enabled, !Task.isCancelled, announced[record] == nil,
              document?.events.contains(event) == true, ignored[event.id] == nil else { return }
        try await notifications.schedule(.init(identifier:id,title:title,body:body,deliveryDate:date,eventID:event.id,sourceURL:event.sourceURL))
        guard ticket == generation, messagesEnabled, enabled, !Task.isCancelled,
              document?.events.contains(event) == true, ignored[event.id] == nil else {
            notifications.removePending(identifiers:[id]);notifications.removeDelivered(identifiers:[id]);return
        }
        announced[record] = event.expiresAt;persistRecords()
    }
    private func cancelAll() {
        notifications.removeAll()
        announced = announced.filter { !$0.key.hasSuffix("|before") && !$0.key.hasSuffix("|time") }
        persistRecords()
    }
    private func ignore(_ id: String) {
        guard !demo, ResetAnnouncementDocument.validID(id) else { return }
        ignored[id] = document?.events.first(where:{ $0.id == id })?.expiresAt ?? now().addingTimeInterval(86_400)
        let ids = ["announce","before","time","completed","cancelled"].map { self.identifier(id,$0) }
        notifications.removePending(identifiers:ids);notifications.removeDelivered(identifiers:ids)
        prune();persistRecords();selectUpcoming();processNotifications(replace:true)
    }
    private func handle(_ action: ResetNotificationAction) {
        guard !demo, messagesEnabled else { return }
        switch action {
        case .openPanel: onOpenPanel?()
        }
    }
    private func key(_ event: ResetAnnouncement, _ phase: String) -> String { "\(event.id)|\(event.revision)|\(phase)" }
    private func identifier(_ id: String, _ phase: String) -> String { "codex-buddy.reset.\(id).\(phase)" }
    private static func readDates(_ defaults: UserDefaults, key: String, limit: Int) -> [String:Date] {
        let values = defaults.dictionary(forKey:preferencePrefix+key) as? [String:Date] ?? [:]
        guard values.count <= limit else { return [:] }
        return values.filter { $0.key.utf8.count <= 120 && $0.value.timeIntervalSince1970.isFinite }
    }
    private func prune(at timestamp: Date? = nil) {
        guard !demo else { return }
        let time = timestamp ?? now()
        let oldAnnounced = announced, oldIgnored = ignored
        announced = Dictionary(uniqueKeysWithValues:announced.filter { $0.value > time && $0.value < time.addingTimeInterval(367*86_400) }.sorted { $0.value > $1.value }.prefix(256).map { ($0.key,$0.value) })
        ignored = Dictionary(uniqueKeysWithValues:ignored.filter { $0.value > time && $0.value < time.addingTimeInterval(367*86_400) }.sorted { $0.value > $1.value }.prefix(100).map { ($0.key,$0.value) })
        if let document, !document.events.isEmpty, document.events.allSatisfy({ $0.expiresAt <= time }) {
            self.document = nil;etag = nil
            preferences.removeObject(forKey:Self.preferencePrefix+"cache");preferences.removeObject(forKey:Self.preferencePrefix+"etag")
        }
        if oldAnnounced != announced || oldIgnored != ignored { persistRecords() }
    }
    private func persistRecords() {
        guard !demo else { return }
        if announced.count > 256 { announced = Dictionary(uniqueKeysWithValues:announced.sorted { $0.value > $1.value }.prefix(256).map { ($0.key,$0.value) }) }
        if ignored.count > 100 { ignored = Dictionary(uniqueKeysWithValues:ignored.sorted { $0.value > $1.value }.prefix(100).map { ($0.key,$0.value) }) }
        preferences.set(announced,forKey:Self.preferencePrefix+"announced")
        preferences.set(ignored,forKey:Self.preferencePrefix+"ignored")
        preferences.set(revisions,forKey:Self.preferencePrefix+"revisions")
    }
}
