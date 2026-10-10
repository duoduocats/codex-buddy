import Foundation
import Combine

enum ChallengeRecordKind: String, Codable { case improvement, reset }
enum ChallengePhase { case upcoming, active, history }
struct ChallengeRecord: Codable, Equatable, Identifiable {
    let id: String
    let revision: Int
    let day: Int
    let kind: ChallengeRecordKind
    let status: ResetAnnouncementStatus
    let title: ResetLocalizedText
    let body: ResetLocalizedText
    let sourceURL: URL
    let collectedAt: Date
    let sourcePublishedAt: Date?
    var category: String {
        if status == .cancelled { return L("已取消", "Cancelled") }
        return kind == .improvement ? L("产品改进", "Improvement") : L("额度重置", "Quota reset")
    }
    var timeDescription: String {
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmmz")
        let text = formatter.string(from:sourcePublishedAt ?? collectedAt)
        return sourcePublishedAt == nil ? L("收录于 \(text)", "Collected \(text)") : L("发布于 \(text)", "Published \(text)")
    }
}

struct TiboChallengeDocument: Codable, Equatable, Identifiable {
    static let maximumBytes = 131_072
    static let feedURL = URL(string:"https://raw.githubusercontent.com/duoduocats/codex-buddy/main/announcements/tibo-28.json")!
    let schemaVersion: Int
    let id: String
    let revision: Int
    let startDate: String
    let days: Int
    let timeZone: String
    let sourceURL: URL
    let title: ResetLocalizedText
    let statement: ResetLocalizedText
    let records: [ChallengeRecord]
    var calendar: Calendar {
        var value = Calendar(identifier:.gregorian)
        value.timeZone = TimeZone(identifier:timeZone)!
        return value
    }
    var start: Date {
        let parts = startDate.split(separator:"-").compactMap { Int($0) }
        return calendar.date(from:DateComponents(year:parts[0],month:parts[1],day:parts[2]))!
    }
    var end: Date { calendar.date(byAdding:.day,value:days,to:start)! }
    func date(for day: Int) -> Date { calendar.date(byAdding:.day,value:day-1,to:start)! }
    func currentDay(at now: Date) -> Int {
        calendar.dateComponents([.day],from:start,to:calendar.startOfDay(for:now)).day! + 1
    }
    func isActive(at now: Date) -> Bool { now >= start && now < end }
    func phase(at now: Date) -> ChallengePhase { now < start ? .upcoming : now < end ? .active : .history }
    func records(for day: Int) -> [ChallengeRecord] { records.filter { $0.day == day } }
    func dateText(for day: Int, includeWeekday: Bool = false) -> String {
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(includeWeekday ? "MMMEd" : "MMMd")
        return formatter.string(from:date(for:day))
    }
    var periodText: String {
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return "\(formatter.string(from:start)) – \(formatter.string(from:date(for:days)))"
    }
    var activityMessages: [ResetAnnouncement] {
        // Reset records already enter the reset feed. Activity alerts contain improvements only.
        records.filter { $0.kind == .improvement }.sorted {
            $0.day != $1.day ? $0.day > $1.day : $0.collectedAt > $1.collectedAt
        }.prefix(1).map { record in
            ResetAnnouncement(id:"activity-"+record.id,revision:record.revision,type:"activity",status:record.status,
                publishedAt:record.sourcePublishedAt ?? record.collectedAt,expiresAt:end,
                titleText:title,
                bodyText:.init(zh:"第 \(record.day) 天 · \(record.title.zh)\n\(record.body.zh)",
                               en:"Day \(record.day) · \(record.title.en)\n\(record.body.en)"),
                sourceURL:record.sourceURL,timestampBasis:record.sourcePublishedAt == nil ? .collected : .source)
        }
    }
    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ResetAnnouncementFailure.invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard text.count <= 32, text.hasSuffix("Z") else { throw ResetAnnouncementFailure.invalid }
            let formatter = ISO8601DateFormatter();formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            guard let date = formatter.date(from:text) ?? ISO8601DateFormatter().date(from:text) else { throw ResetAnnouncementFailure.invalid }
            return date
        }
        let value = try decoder.decode(Self.self,from:data)
        // The temporary campaign's calendar is fixed; server data cannot change its boundaries.
        guard value.schemaVersion == 1, value.id == "tibo-28-2026-10-05", (1...1_000_000).contains(value.revision),
              value.startDate == "2026-10-05", value.days == 28, value.timeZone == "America/Los_Angeles",
              validSource(value.sourceURL), ResetAnnouncementDocument.validText(value.title,maximum:160),
              ResetAnnouncementDocument.validText(value.statement,maximum:600), value.records.count <= 84,
              Set(value.records.map(\.id)).count == value.records.count else { throw ResetAnnouncementFailure.invalid }
        for record in value.records {
            guard ResetAnnouncementDocument.validID(record.id), (1...1_000_000).contains(record.revision),
                  (1...28).contains(record.day), validSource(record.sourceURL),
                  record.collectedAt >= value.start, record.collectedAt <= now,
                  ResetAnnouncementDocument.validText(record.title,maximum:160),
                  ResetAnnouncementDocument.validText(record.body,maximum:1_000),
                  record.kind != .improvement || record.status != .scheduled else { throw ResetAnnouncementFailure.invalid }
            if let date = record.sourcePublishedAt {
                guard date >= value.start.addingTimeInterval(-86_400), date <= record.collectedAt else { throw ResetAnnouncementFailure.invalid }
            }
        }
        return value
    }
    static func validSource(_ url: URL) -> Bool {
        ResetAnnouncementDocument.validSourceURL(url) && ["x.com","twitter.com"].contains(url.host?.lowercased() ?? "") &&
            url.path.split(separator:"/").first?.lowercased() == "thsottiaux"
    }
    func accepts(_ newer: Self) -> Bool {
        guard newer.revision >= revision, newer.revision != revision || newer == self else { return false }
        return records.allSatisfy { previous in
            guard let next = newer.records.first(where:{ $0.id == previous.id }) else { return false }
            return next.revision >= previous.revision && (next.revision != previous.revision || next == previous)
        }
    }
    // Public, verified baseline keeps the first record available before the feed is published,
    // and when the service is temporarily unreachable. No account or usage data is embedded.
    static let initial = Self(schemaVersion:1,id:"tibo-28-2026-10-05",revision:1,startDate:"2026-10-05",days:28,
        timeZone:"America/Los_Angeles",sourceURL:URL(string:"https://x.com/thsottiaux/status/2106845241357824205")!,
        title:.init(zh:"Tibo 的 28 天挑战",en:"Tibo’s 28-day challenge"),
        statement:.init(zh:"Tibo 承诺：接下来的 28 天，每天推出一项对多数 Codex / Work 用户有用的明显改进，或进行一次完整额度重置。",
                        en:"Tibo’s pledge: over 28 days, ship a clear improvement useful to most Codex / Work users each day, or a full quota reset."),
        records:[ChallengeRecord(id:"tibo-day-1-speed",revision:1,day:1,kind:.improvement,status:.completed,
            title:.init(zh:"默认速度提升约 50%",en:"Default speed improved by about 50%"),
            body:.init(zh:"Tibo 宣布优化 GPT-6 Astra 和 GPT-6.1 Sol 的默认速度，覆盖订阅中的各产品及使用 ChatGPT 登录的合作伙伴产品。用户无需操作；原帖预计改进会在随后两小时内逐步生效。",
                       en:"Tibo announced faster defaults for GPT-6 Astra and GPT-6.1 Sol across subscription products and partners using Sign in With ChatGPT. No user action is needed; the post expected rollout over the following two hours."),
            sourceURL:URL(string:"https://x.com/thsottiaux/status/2107158998495748264")!,
            collectedAt:ISO8601DateFormatter().date(from:"2026-10-06T02:09:40Z")!,sourcePublishedAt:nil)])
}

@MainActor final class TiboChallengeManager: ObservableObject {
    @Published private(set) var document: TiboChallengeDocument
    @Published private(set) var enabled: Bool
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var error: String?
    @Published private(set) var windowNow = Date()
    private var windowTimer: Timer?
    var onDisabled: (() -> Void)?
    private let preferences: UserDefaults
    private let client: ResetAnnouncementFetching
    private let clock: () -> Date
    private var etag: String?
    private var lastAttempt: Date?
    private var failures = 0
    private var connectionFailure = false
    private var serverNotBefore: Date?
    private var started = false
    private var demo = false
    private var generation = 0
    private var task: Task<Void,Never>?
    static let prefix = "tiboChallenge."
    init(preferences: UserDefaults = .standard, enabled: Bool = true,
         client: ResetAnnouncementFetching? = nil, initialDocument: TiboChallengeDocument = .initial, now: @escaping () -> Date = { Date() }) {
        self.preferences = preferences;self.enabled = enabled;self.clock = now
        self.client = client ?? ResetAnnouncementClient(feedURL:TiboChallengeDocument.feedURL,maximumBytes:TiboChallengeDocument.maximumBytes,
            now:now,validate:{ _ = try TiboChallengeDocument.decode($0,now:now()) })
        serverNotBefore = preferences.object(forKey:Self.prefix+"serverNotBefore") as? Date
        document = initialDocument
        if let data = preferences.data(forKey:Self.prefix+"cache"),
           let cached = try? TiboChallengeDocument.decode(data,now:now()), document.accepts(cached) {
            document = cached;etag = ResetAnnouncementClient.validETag(preferences.string(forKey:Self.prefix+"etag"))
            self.client.retainCachedData(data)
            lastChecked = preferences.object(forKey:Self.prefix+"lastChecked") as? Date
        }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if !value { stopRequest();error = nil;onDisabled?() }
        else { lastAttempt = nil;failures = 0;if started { check() } }
    }
    func start() {
        guard !demo, !started else { return }
        started = true
        // Restarting the same service should behave like a fresh process.
        lastAttempt = nil;failures = 0
        check()
    }
    func stop() { started = false;stopRequest();setWindowVisible(false) }
    func setWindowVisible(_ visible: Bool) {
        windowTimer?.invalidate();windowTimer = nil
        guard visible else { return }
        refreshClock()
        guard !demo else { return }
        check(force:true)
        windowTimer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.refreshClock() }
        }
        windowTimer?.tolerance = 5
    }
    func refreshClock() { windowNow = clock() }
    private func stopRequest() { generation += 1;task?.cancel();task = nil;checking = false }
    func tick() { if started { check() } }
    func networkRecovered() {
        guard started, enabled, connectionFailure else { return }
        connectionFailure = false;lastAttempt = nil;check()
    }
    func check(force: Bool = false) {
        guard enabled, !demo, !checking else { return }
        let timestamp = clock()
        if let date = serverNotBefore, date > timestamp { return }
        if let lastAttempt {
            let elapsed = timestamp.timeIntervalSince(lastAttempt)
            let interval = failures == 0 && !document.isActive(at:timestamp) ? 3_600 : PublicFeedRefreshPolicy.interval(failures:failures)
            if elapsed >= 0 && elapsed < (force ? 30 : interval) { return }
        }
        lastAttempt = timestamp;checking = true;generation += 1
        let ticket = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == generation { task = nil;checking = false } }
            do {
                let result: ResetFetchResult
                if force { result = try await client.fetchFresh(etag:etag) }
                else { result = try await client.fetch(etag:etag) }
                try Task.checkCancellation()
                guard enabled, ticket == generation else { return }
                if case let .document(data,newETag) = result {
                    let next = try TiboChallengeDocument.decode(data,now:clock())
                    guard document.accepts(next) else { throw ResetAnnouncementFailure.invalid }
                    if next != document { document = next }
                    etag = ResetAnnouncementClient.validETag(newETag)
                    preferences.set(data,forKey:Self.prefix+"cache");preferences.set(etag,forKey:Self.prefix+"etag")
                    client.retainCachedData(data)
                } else if etag == nil { throw ResetAnnouncementFailure.invalid }
                lastChecked = clock();preferences.set(lastChecked,forKey:Self.prefix+"lastChecked")
                serverNotBefore = client.retryNotBefore;preferences.set(serverNotBefore,forKey:Self.prefix+"serverNotBefore")
                failures = 0;connectionFailure = false;error = nil
            } catch is CancellationError { }
            catch ResetAnnouncementFailure.notPublished {
                guard ticket == generation, !Task.isCancelled else { return }
                failures = min(failures+1,5)
                connectionFailure = false
                // Before the first campaign feed is published, the verified baseline is expected.
                error = lastChecked == nil ? nil : L("暂时无法更新，已保留最近记录。", "Could not update. The latest saved records are still available.")
            }
            catch {
                guard ticket == generation, !Task.isCancelled else { return }
                failures = min(failures+1,5)
                connectionFailure = PublicFeedRefreshPolicy.connectionFailed(error)
                if case ResetAnnouncementFailure.retryAfter(let date) = error {
                    serverNotBefore = date;preferences.set(date,forKey:Self.prefix+"serverNotBefore")
                }
                self.error = L("暂时无法更新，已保留最近记录。", "Could not update. The latest saved records are still available.")
            }
        }
    }
    func useDemo(now: Date = Date(), document sample: TiboChallengeDocument = .initial) {
        stopRequest();demo = true;document = sample;windowNow = now;lastChecked = nil;error = nil
    }
}
