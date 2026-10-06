import Foundation

// Every request and event in this executable is synthetic. It never reads the
// user's Codex login, contacts GitHub, or asks macOS for notification permission.
final class ResetFeedFixture: URLProtocol {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String:String] = [:]
        var responseURL: URL?
        var failure: Error?
    }
    private static let lock = NSLock()
    private static var reply = Reply(status:200,body:Data())
    private static var recorded = [URLRequest]()
    static func configure(_ value: Reply) {
        lock.lock();defer { lock.unlock() }
        reply = value;recorded = []
    }
    static var requests: [URLRequest] {
        lock.lock();defer { lock.unlock() };return recorded
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock();Self.recorded.append(request);let fixture = Self.reply;Self.lock.unlock()
        if let failure = fixture.failure {
            client?.urlProtocol(self,didFailWithError:failure);return
        }
        let response = HTTPURLResponse(url:fixture.responseURL ?? request.url!,statusCode:fixture.status,
                                       httpVersion:nil,headerFields:fixture.headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class ResetCenterFixture: ResetNotificationDelivering {
    var permission: ResetNotificationAuthorization = .notDetermined
    var consent = true
    var permissionRequests = 0
    var authorizationChecks = 0
    var schedules = [ResetNotification]()
    var pending = [String:ResetNotification]()
    var removedPending = Set<String>()
    var removedDelivered = Set<String>()
    var removeAllCount = 0
    var scheduleError: Error?
    var pauseNext = false
    private(set) var suspended = [CheckedContinuation<Void,Never>]()
    func authorization() async -> ResetNotificationAuthorization {
        authorizationChecks += 1;return permission
    }
    func requestAuthorization() async throws -> Bool {
        permissionRequests += 1
        permission = consent ? .allowed : .denied
        return consent
    }
    func schedule(_ notification: ResetNotification) async throws {
        if let error = scheduleError { throw error }
        schedules.append(notification)
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { suspended.append($0) }
        }
        pending[notification.identifier] = notification
    }
    func removePending(identifiers: [String]) {
        removedPending.formUnion(identifiers)
        for identifier in identifiers { pending.removeValue(forKey:identifier) }
    }
    func removeDelivered(identifiers: [String]) { removedDelivered.formUnion(identifiers) }
    func removeAll() { removeAllCount += 1;pending = [:] }
    func resumeSchedules() { let values = suspended;suspended = [];for value in values { value.resume() } }
}

final class ResetFetchFixture: ResetAnnouncementFetching {
    var reply: ResetFetchResult
    var failure: Error?
    private(set) var requests = [String?]()
    init(_ data: Data) { reply = .document(data,etag:"\"manager-fixture\"") }
    func fetch(etag: String?) async throws -> ResetFetchResult {
        requests.append(etag)
        if let failure { throw failure }
        return reply
    }
}

@MainActor final class SuspendedResetFetchFixture: ResetAnnouncementFetching {
    var pending: CheckedContinuation<ResetFetchResult,Error>?
    var requests = 0
    func fetch(etag:String?) async throws -> ResetFetchResult {
        requests += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete(_ data:Data) {
        let value = pending;pending = nil
        value?.resume(returning:.document(data,etag:nil))
    }
}

@main struct ResetReminderTests {
    static let origin = Date(timeIntervalSince1970:1_790_906_400)
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter();formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    static func event(id: String = "synthetic-message", revision: Int = 1,
                      now: Date = origin, deadline: Date? = nil,
                      type: String = "message", status: String? = nil) -> [String:Any] {
        var value: [String:Any] = [
            "id":id,"revision":revision,"type":type,
            "publishedAt":formatter.string(from:now.addingTimeInterval(-60)),
            "expiresAt":formatter.string(from:now.addingTimeInterval(86_400)),
            "title":["zh":"合成消息","en":"Synthetic message"],
            "body":["zh":"仅供测试的公告正文。","en":"An announcement body used only for testing."]
        ]
        if let status { value["status"] = status }
        if let deadline { value["scheduledAt"] = formatter.string(from:deadline) }
        if type == "globalReset" {
            value["appliesTo"] = ["zh":"付费账户","en":"Paid accounts"]
            value["sourceURL"] = "https://x.com/thsottiaux/status/1234567890123456789"
        }
        return value
    }
    static func document(_ events: [[String:Any]], schema: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject:["schemaVersion":schema,"events":events],options:[.sortedKeys])
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(),message)
    }
    static func rejects(_ data: Data, _ label: String) {
        do { _ = try ResetAnnouncementDocument.decode(data,now:origin);preconditionFailure("Accepted invalid message feed: \(label)") }
        catch {}
    }
    @MainActor static func main() async throws {
        try decodeTests()
        try localTimeTests()
        try await fetchTests()
        try await permissionTests()
        try await lifecycleTests()
        try await historyTests()
        try await cacheFailureTests()
        try await concurrentRevisionTests()
        try await scheduleFailureTests()
        try await panelDismissalTests()
        try await independentMessageSettingsTests()
        try await receivingCancellationTests()
        try await categorySettingsTests()
        try await activitySystemReminderTests()
    }
    static func decodeTests() throws {
        let decoded = try ResetAnnouncementDocument.decode(try document([event()]),now:origin)
        let message = decoded.events[0]
        require(decoded.events.count == 1 && message.type == "message" && message.status == .scheduled,
                "A generic bilingual message must decode without a status field")
        require(message.scheduledAt == nil && message.sourceURL == nil && message.appliesTo.isEmpty,
                "Messages must not require reset-specific scope, deadline or source")
        var enriched = event(deadline:origin.addingTimeInterval(3_600))
        enriched["sourceURL"] = "https://openai.com/index/"
        enriched["appliesTo"] = ["zh":"测试用户","en":"Test users"]
        let full = try ResetAnnouncementDocument.decode(try document([enriched]),now:origin).events[0]
        require(full.scheduledAt == origin.addingTimeInterval(3_600) && full.sourceURL?.host == "openai.com" && !full.appliesTo.isEmpty,
                "Optional message fields must retain their validated values")
        let legacy = try ResetAnnouncementDocument.decode(try document([event(deadline:origin.addingTimeInterval(3_600),type:"globalReset")]),now:origin)
        require(legacy.events[0].type == "globalReset","Existing reset messages must remain readable")
        var missingDeadline = event(type:"globalReset");missingDeadline["status"] = "scheduled"
        rejects(try document([missingDeadline]),"scheduled legacy reset without deadline")
        for field in ["sourceURL","appliesTo"] {
            var missing = event(deadline:origin.addingTimeInterval(3_600),type:"globalReset");missing.removeValue(forKey:field)
            rejects(try document([missing]),"legacy reset missing \(field)")
        }
        rejects(Data("not JSON".utf8),"malformed JSON")
        rejects(Data("[]".utf8),"wrong root")
        rejects(try document([event()],schema:2),"unsupported schema")
        rejects(try document([event(),event()]),"duplicate IDs")
        rejects(Data(repeating:32,count:65_537),"oversize document")
        for (key,value) in [
            ("type","quotaReset"),("status","verified"),("scheduledAt","not-a-date"),
            ("sourceURL","http://x.com/thsottiaux/status/123"),
            ("sourceURL","https://x.com.evil.example/thsottiaux/status/123"),
            ("sourceURL","https://x.com@evil.example/thsottiaux/status/123"),
            ("sourceURL","https://x.com/thsottiaux/status/123?token=private"),
            ("sourceURL","file:///private/tmp/source"),
            ("sourceURL","https://x.com/thsottiaux/status/123#source"),
            ("sourceURL","https://github.com/another-owner/codex-buddy/releases"),
            ("sourceURL","https://github.com/duoduocats/codex-buddy/issues/new"),
            ("sourceURL","https://github.com/duoduocats/codex-buddy/releases?client=private")
        ] {
            var invalid = event();invalid[key] = value
            rejects(try document([invalid]),"\(key)=\(value)")
        }
        for source in ["https://github.com/duoduocats/codex-buddy/issues/123",
                       "https://github.com/duoduocats/codex-buddy/releases/tag/v2.1.0",
                       "https://github.com/duoduocats/codex-buddy/blob/main/docs/QUALITY.md"] {
            var linked = event();linked["sourceURL"] = source
            let validLink = try ResetAnnouncementDocument.decode(try document([linked]),now:origin).events[0].sourceURL
            require(validLink?.absoluteString == source,
                    "Validated links within the public project must retain their exact URL")
        }
        for revision in [0,-1,1_000_001] { rejects(try document([event(revision:revision)]),"out-of-bounds revision") }
        for id in ["",String(repeating:"x",count:81),"../message","user@example.com","contains space"] {
            rejects(try document([event(id:id)]),"unsafe or overlong ID")
        }
        rejects(try document((0...50).map { event(id:"synthetic-\($0)") }),"too many events")
        var inverted = event();inverted["expiresAt"] = formatter.string(from:origin.addingTimeInterval(-120))
        rejects(try document([inverted]),"expiry precedes publication")
        var far = event();far["scheduledAt"] = formatter.string(from:origin.addingTimeInterval(366*86_400))
        rejects(try document([far]),"unbounded deadline")
        var future = event();future["publishedAt"] = formatter.string(from:origin.addingTimeInterval(60))
        rejects(try document([future]),"not yet published message")
        var offset = event();offset["scheduledAt"] = "2026-10-03T10:00:00-08:00"
        rejects(try document([offset]),"timestamp must be explicit UTC")
        for field in ["title","body","appliesTo"] {
            var missingLanguage = event();missingLanguage[field] = ["zh":"合成"]
            rejects(try document([missingLanguage]),"present \(field) missing English")
            var blank = event();blank[field] = ["zh":" ","en":"Synthetic"]
            rejects(try document([blank]),"empty localized \(field)")
            var huge = event();huge[field] = ["zh":"合成","en":String(repeating:"x",count:1_001)]
            rejects(try document([huge]),"overlong localized \(field)")
            var control = event();control[field] = ["zh":"合成","en":"Synthetic\u{0000}text"]
            rejects(try document([control]),"control character in \(field)")
        }
        print("Message document tests passed: optional fields, compatibility, URL/text/date validation and bounded schema")
    }
    static func localTimeTests() throws {
        let deadline = formatter.date(from:"2026-07-01T00:05:00Z")!
        let message = try ResetAnnouncementDocument.decode(try document([event(now:deadline,deadline:deadline)]),now:deadline).events[0]
        let hongKong = TimeZone(identifier:"Asia/Hong_Kong")!
        let losAngeles = TimeZone(identifier:"America/Los_Angeles")!
        let utc = TimeZone(identifier:"UTC")!
        let us = Locale(identifier:"en_US"), uk = Locale(identifier:"en_GB")
        let hongKongText = message.scheduledDateText(locale:us,timeZone:hongKong)!
        require(hongKongText.contains("Jul 1, 2026") && hongKongText.contains("8:05") &&
                hongKongText.contains("AM") && hongKongText.contains("GMT+8"),
                "Hong Kong presentation must include the local date, hour, minute and time zone")
        let losAngelesText = message.scheduledDateText(locale:us,timeZone:losAngeles)!
        require(losAngelesText.contains("Jun 30, 2026") && losAngelesText.contains("5:05") &&
                losAngelesText.contains("PM") && losAngelesText.contains("PDT"),
                "Los Angeles presentation must use the previous local date and event-time daylight saving offset")
        let utcText = message.scheduledDateText(locale:uk,timeZone:utc)!
        require(utcText.contains("1 Jul 2026") && utcText.contains("00:05") && utcText.contains("GMT") &&
                !utcText.contains("AM") && !utcText.contains("PM"),
                "UTC presentation must include midnight minutes and the locale's 24-hour time format")
        let losAngeles24 = message.scheduledDateText(locale:uk,timeZone:losAngeles)!
        require(losAngeles24.contains("30 Jun 2026") && losAngeles24.contains("17:05") && losAngeles24.contains("GMT-7"),
                "Changing locale and time zone must recalculate both date and hour cycle without a frozen formatter")
        let chineseText = message.scheduledDateText(locale:Locale(identifier:"zh_HK"),timeZone:hongKong)!
        require(chineseText.contains("2026年7月1日") && chineseText.contains("8:05") && chineseText.contains("GMT+8"),
                "Localized date order must retain the exact local date and time-zone label")
        require(message.scheduledDateText(locale:us,timeZone:hongKong) == hongKongText,
                "A later presentation must use the supplied settings rather than retain the previous time zone")
        require(message.timeDescription(locale:us,timeZone:losAngeles) == L("预计时间：\(losAngelesText)", "Expected time: \(losAngelesText)"),
                "Scheduled message time must be labeled as expected time in visible and accessible descriptions")
        let plain = try ResetAnnouncementDocument.decode(try document([event(now:deadline)]),now:deadline).events[0]
        require(plain.scheduledDateText(locale:us,timeZone:utc) == nil && plain.dateText == plain.statusTitle,
                "A message without scheduledAt must not invent a date or require a deadline")
        let publishedText = plain.publishedDateText(locale:us,timeZone:hongKong)
        require(publishedText.contains("Jul 1, 2026") && publishedText.contains("8:04") &&
                publishedText.contains("AM") && publishedText.contains("GMT+8"),
                "A plain message must present its actual publication instant in the local time zone")
        require(plain.timeDescription(locale:us,timeZone:hongKong) == L("发布时间：\(publishedText)", "Published: \(publishedText)"),
                "A plain message's visible and accessible time must be labeled as publication rather than a deadline")
        print("Message local-time tests passed: Hong Kong, Los Angeles summer/DST and previous date, UTC, localized 12/24-hour time, optional deadline and labeled publication time")
    }
    @MainActor static func fetchTests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResetFeedFixture.self]
        configuration.httpAdditionalHeaders = ["Authorization":"synthetic-inherited-secret","Cookie":"synthetic-cookie","User-Agent":"synthetic-version-99.9"]
        let client = ResetAnnouncementClient(configuration:configuration)
        let bytes = try document([event()])
        ResetFeedFixture.configure(.init(status:200,body:bytes,headers:["ETag":"\"synthetic-etag\""]))
        switch try await client.fetch(etag:nil) {
        case .document(let body,let etag): require(body == bytes && etag == "\"synthetic-etag\"","Public feed must preserve data and ETag")
        case .notModified: preconditionFailure("Fresh response incorrectly treated as cached")
        }
        let request = ResetFeedFixture.requests[0]
        let url = URL(string:"https://raw.githubusercontent.com/duoduocats/codex-buddy/main/announcements/messages.json")!
        require(ResetFeedFixture.requests.count == 1 && request.url == url,"Messages must use the fixed public HTTPS feed")
        require(request.value(forHTTPHeaderField:"Authorization") == nil && request.value(forHTTPHeaderField:"Cookie") == nil,
                "Public message requests must not carry credentials or cookies")
        require(request.value(forHTTPHeaderField:"User-Agent") == "Codex-Buddy-Announcements" && request.url?.query == nil && request.url?.fragment == nil,
                "Public request must contain neither installed-version nor installation/account identifiers")
        require(request.value(forHTTPHeaderField:"If-None-Match") == nil,"First fetch must not invent a validator")
        ResetFeedFixture.configure(.init(status:304,body:Data()))
        switch try await client.fetch(etag:"\"synthetic-etag\"") {
        case .notModified: break
        case .document: preconditionFailure("304 must not replace cached data")
        }
        require(ResetFeedFixture.requests.first?.url == url && ResetFeedFixture.requests.first?.value(forHTTPHeaderField:"If-None-Match") == "\"synthetic-etag\"",
                "Conditional checks must retain the fixed URL and use the server's validator")
        ResetFeedFixture.configure(.init(status:304,body:Data()))
        _ = try await client.fetch(etag:"synthetic\r\nCookie: forbidden")
        require(ResetFeedFixture.requests.first?.value(forHTTPHeaderField:"If-None-Match") == nil,"Malformed validators must not enter request headers")
        for fixture in [
            ResetFeedFixture.Reply(status:503,body:bytes),
            .init(status:200,body:Data(repeating:32,count:65_537)),
            .init(status:200,body:bytes,responseURL:URL(string:"https://evil.example/feed.json")!),
            .init(status:200,body:bytes,failure:URLError(.notConnectedToInternet))
        ] {
            ResetFeedFixture.configure(fixture)
            do { _ = try await client.fetch(etag:nil);preconditionFailure("Untrusted or failed message feed accepted") }
            catch {}
        }
        print("Message public-fetch tests passed: fixed feed, no credentials/IDs, ETag304, HTTP/offline/origin/size rejection")
    }
    @MainActor static func settle(_ manager: ResetReminderManager) async throws {
        var quiet = 0
        for _ in 0..<500 {
            try await Task.sleep(nanoseconds:1_000_000)
            quiet = manager.checking ? 0 : quiet+1
            if quiet >= 20 { return }
        }
        preconditionFailure("Synthetic message work did not finish")
    }
    @MainActor static func permissionTests() async throws {
        for consent in [true,false] {
            let suite = "buddy-message-permission-tests-\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName:suite)!
            defer { preferences.removePersistentDomain(forName:suite) }
            let client = ResetFetchFixture(try document([event()]))
            let center = ResetCenterFixture();center.consent = consent
            let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
            defer { manager.stop() }
            require(!manager.enabled,"Message notifications must default to opt out")
            manager.start();try await settle(manager)
            require(manager.upcoming?.id == "synthetic-message" && client.requests.count == 1,"Message discovery must work without notification opt in")
            require(center.permissionRequests == 0 && center.authorizationChecks == 0 && center.schedules.isEmpty,
                    "Startup and public fetch must not prompt or authorize notifications")
            manager.setEnabled(true);try await settle(manager)
            require(center.permissionRequests == 1 && manager.enabled == consent,"Only explicit enable may request undecided permission")
            require(center.schedules.count == (consent ? 1 : 0),"One current message may notify only after authorization")
            if !consent {
                require(manager.message != nil,"Denial must explain the recoverable permission state")
                manager.setEnabled(true);try await settle(manager)
                require(center.permissionRequests == 1 && center.schedules.isEmpty,"Denied permissions must not be repeatedly requested")
            }
        }
        let suite = "buddy-message-revoked-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        preferences.set(true,forKey:ResetReminderManager.preferencePrefix+"enabled")
        let center = ResetCenterFixture()
        let manager = ResetReminderManager(preferences:preferences,client:ResetFetchFixture(try document([event()])),notifications:center,now:{origin})
        defer { manager.stop() }
        manager.start();try await settle(manager)
        require(!manager.enabled && center.permissionRequests == 0 && center.schedules.isEmpty,"Stored preference is not system notification authorization")
        print("Message permission tests passed: default opt out, explicit consent, denial, relaunch without automatic permission prompt")
    }
    @MainActor static func lifecycleTests() async throws {
        let suite = "buddy-message-lifecycle-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        // A legacy early-reminder preference must not create old staged alerts.
        preferences.set(true,forKey:ResetReminderManager.preferencePrefix+"before")
        var clock = origin
        let original = event(deadline:origin.addingTimeInterval(3_600))
        let client = ResetFetchFixture(try document([original]))
        let center = ResetCenterFixture();center.permission = .allowed
        let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{clock})
        defer { manager.stop() }
        manager.check();try await settle(manager);manager.setEnabled(true);try await settle(manager)
        require(center.schedules.count == 1 && center.schedules[0].deliveryDate == nil,"A message has one immediate announcement, never deadline stages")
        require(center.schedules[0].title == manager.upcoming?.title &&
                center.schedules[0].body.hasPrefix((manager.upcoming?.body ?? "")+"\n") &&
                center.schedules[0].body.hasSuffix(manager.upcoming!.timeDescription()),
                "Native notification must preserve the message content and include its local time")
        require(center.schedules[0].sourceURL == nil,"A message without source must not invent a URL")
        clock = origin.addingTimeInterval(900);client.reply = .notModified
        manager.check();try await settle(manager)
        require(client.requests.count == 2 && client.requests.last! == "\"manager-fixture\"" && center.schedules.count == 1,"304 retains message and does not replay its notification")
        manager.stop()
        let restored = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{clock})
        defer { restored.stop() }
        restored.start();try await settle(restored)
        require(restored.enabled && restored.upcoming?.id == "synthetic-message" && center.schedules.count == 1,"Notification de-duplication must survive restart")
        clock = clock.addingTimeInterval(31)
        var revised = event(revision:2,now:clock,deadline:clock.addingTimeInterval(7_200))
        revised["title"] = ["zh":"修订后的消息","en":"Revised message"]
        client.reply = .document(try document([revised]),etag:"\"revision-two\"")
        restored.check(force:true);try await settle(restored)
        require(center.schedules.count == 2 && center.schedules.last?.title == restored.upcoming?.title,"A valid new revision can announce exactly once")
        require(center.schedules.allSatisfy { $0.deliveryDate == nil },"Revisions must not schedule early, deadline or status alerts")
        restored.ignoreUpcoming();try await settle(restored)
        require(restored.upcoming == nil && center.pending.isEmpty,"Persistent ignore must hide the message and clear its notifications")
        let ignoredRestore = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{clock})
        defer { ignoredRestore.stop() }
        ignoredRestore.start();try await settle(ignoredRestore)
        require(ignoredRestore.upcoming == nil && center.schedules.count == 2,"Ignored message must stay ignored after restart")
        ignoredRestore.setEnabled(false);try await settle(ignoredRestore)
        require(!ignoredRestore.enabled && center.removeAllCount > 0,"Turning notifications off must clear outstanding messages")
        print("Message lifecycle tests passed: one announcement, content fidelity, cache304, restart/revision dedupe, ignore and disable")
    }
    @MainActor static func historyTests() async throws {
        for scenario in ["expired","deadline","unpublished","history"] {
            let suite = "buddy-message-history-tests-\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName:suite)!
            defer { preferences.removePersistentDomain(forName:suite) }
            var clock = origin
            var value = event()
            if scenario == "expired" {
                value["publishedAt"] = formatter.string(from:origin.addingTimeInterval(-3_600))
                value["expiresAt"] = formatter.string(from:origin.addingTimeInterval(-1))
            } else if scenario == "deadline" { value["scheduledAt"] = formatter.string(from:origin) }
            var events = [value]
            if scenario == "history" {
                var older = event(id:"older-unrelated");older["publishedAt"] = formatter.string(from:origin.addingTimeInterval(-120))
                events.insert(older,at:0)
            }
            let client = ResetFetchFixture(try document(events))
            let center = ResetCenterFixture();center.permission = .allowed
            let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{clock})
            defer { manager.stop() }
            manager.start();try await settle(manager);manager.setEnabled(true);try await settle(manager)
            if ["expired","deadline"].contains(scenario) {
                require(manager.panelAnnouncement(at:clock) == nil && center.schedules.isEmpty,"Overdue or expired messages must not replay")
            } else if scenario == "unpublished" {
                var future = event(revision:2);future["publishedAt"] = formatter.string(from:origin.addingTimeInterval(60))
                clock = origin.addingTimeInterval(31);client.reply = .document(try document([future]),etag:"\"future\"")
                manager.check(force:true);try await settle(manager)
                require(manager.upcoming?.revision == 1 && center.schedules.count == 1,"Unpublished message must fail closed and retain valid cached content")
            } else {
                require(center.schedules.map(\.eventID) == ["synthetic-message"],"Initial opt in must not replay older unrelated active messages")
                clock = origin.addingTimeInterval(31);client.reply = .notModified
                manager.check(force:true);try await settle(manager)
                require(center.schedules.count == 1,"Repeated304 must not turn unseen historical messages into new notifications")
                clock = clock.addingTimeInterval(31)
                var fresh = event(id:"new-message",now:clock);fresh["publishedAt"] = formatter.string(from:clock)
                client.reply = .document(try document(events+[fresh]),etag:"\"new-message\"")
                manager.check(force:true);try await settle(manager)
                require(center.schedules.map(\.eventID) == ["synthetic-message","new-message"],"A newly published message must notify without replaying old unrelated history")
            }
        }
        print("Message history tests passed: overdue/expired suppression, future publication rejection, opt-in history suppression, newly published messages")
    }
    @MainActor static func cacheFailureTests() async throws {
        let suite = "buddy-message-cache-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        var clock = origin
        let bytes = try document([event()])
        let client = ResetFetchFixture(bytes)
        let center = ResetCenterFixture()
        let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{clock})
        defer { manager.stop() }
        manager.check();manager.check();try await settle(manager)
        require(client.requests.count == 1,"Concurrent message checks must stay single-flight")
        clock = origin.addingTimeInterval(899);manager.check();try await settle(manager)
        require(client.requests.count == 1,"Public message checks must poll no sooner than15 minutes")
        clock = origin.addingTimeInterval(900);client.reply = .document(Data("malformed".utf8),etag:"\"bad\"")
        manager.check(force:true);try await settle(manager)
        require(manager.upcoming?.id == "synthetic-message" && preferences.data(forKey:ResetReminderManager.preferencePrefix+"cache") == bytes &&
                preferences.string(forKey:ResetReminderManager.preferencePrefix+"etag") == "\"manager-fixture\"","Malformed response must not erase cached message or validator")
        clock = origin.addingTimeInterval(2_699);manager.check(force:true);try await settle(manager)
        require(client.requests.count == 2,"Manual/wake checks must respect outage backoff")
        clock = origin.addingTimeInterval(2_700);client.reply = .notModified
        manager.check(force:true);try await settle(manager)
        require(client.requests.count == 3 && manager.upcoming?.id == "synthetic-message","304 after backoff must preserve message and restore normal cadence")
        clock = clock.addingTimeInterval(31)
        var altered = event();altered["body"] = ["zh":"未增修订号的改动","en":"Changed without revision"]
        client.reply = .document(try document([altered]),etag:"\"altered\"")
        manager.check(force:true);try await settle(manager)
        require(preferences.data(forKey:ResetReminderManager.preferencePrefix+"cache") == bytes,"Same revision must not accept changed content")
        clock = clock.addingTimeInterval(1_800);client.reply = .document(try document([event(revision:2,now:clock)]),etag:"\"second\"")
        manager.check(force:true);try await settle(manager)
        require(manager.upcoming?.revision == 2,"Legitimate higher revision must replace cached message")
        clock = clock.addingTimeInterval(31);client.reply = .document(bytes,etag:"\"stale\"")
        manager.check(force:true);try await settle(manager)
        require(manager.upcoming?.revision == 2 && preferences.string(forKey:ResetReminderManager.preferencePrefix+"etag") == "\"second\"","Stale feed must not downgrade message revision")
        manager.stop();preferences.set(Data("corrupt cache".utf8),forKey:ResetReminderManager.preferencePrefix+"cache")
        preferences.set("\"corrupt\"",forKey:ResetReminderManager.preferencePrefix+"etag")
        let restored = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{clock})
        defer { restored.stop() }
        require(restored.upcoming == nil && preferences.data(forKey:ResetReminderManager.preferencePrefix+"cache") == nil && preferences.string(forKey:ResetReminderManager.preferencePrefix+"etag") == nil,
                "Corrupt restored cache must fail closed and discard validator")
        print("Message cache tests passed: single-flight, cadence, backoff, valid cache retention, revision integrity and corrupt-cache rejection")
    }
    @MainActor static func concurrentRevisionTests() async throws {
        for action in ["revise","remove","disable","disable-receiving","ignore"] {
            let suite = "buddy-message-concurrent-tests-\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName:suite)!
            defer { preferences.removePersistentDomain(forName:suite) }
            var clock = origin
            let client = ResetFetchFixture(try document([event()]))
            let center = ResetCenterFixture();center.permission = .allowed;center.pauseNext = true
            let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{clock})
            defer { manager.stop();center.resumeSchedules() }
            manager.check();try await settle(manager);manager.setEnabled(true);try await settle(manager)
            require(center.suspended.count == 1,"Test must suspend an actual in-flight announcement operation")
            if action == "disable" { manager.setEnabled(false) }
            else if action == "disable-receiving" { manager.setMessagesEnabled(false) }
            else if action == "ignore" { manager.ignoreUpcoming() }
            else {
                clock = origin.addingTimeInterval(60)
                if action == "remove" { client.reply = .document(try document([]),etag:"\"removed\"") }
                else {
                    var revised = event(revision:2,now:clock);revised["title"] = ["zh":"最新修订","en":"Newest revision"]
                    revised["publishedAt"] = formatter.string(from:clock)
                    client.reply = .document(try document([revised]),etag:"\"revised\"")
                }
                manager.check(force:true)
            }
            try await settle(manager);center.resumeSchedules();try await settle(manager)
            if action == "revise" {
                require(center.pending.count == 1 && center.pending.values.first?.title == manager.upcoming?.title && center.pending.values.first?.title == L("最新修订","Newest revision"),
                        "A stale in-flight completion must neither resurrect old content nor erase the newer message")
            } else { require(center.pending.isEmpty,"Removed, disabled or ignored message must not return after old notification operation completes") }
            require(center.schedules.allSatisfy { $0.deliveryDate == nil },"Concurrent operations must remain single immediate announcements")
        }
        print("Message concurrency tests passed: stale async delivery cannot revive removed content or erase a newer revision")
    }
    @MainActor static func scheduleFailureTests() async throws {
        let suite = "buddy-message-schedule-failure-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        var clock = origin
        let client = ResetFetchFixture(try document([event()]))
        let center = ResetCenterFixture();center.permission = .allowed;center.scheduleError = URLError(.networkConnectionLost)
        let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{clock})
        defer { manager.stop() }
        manager.check();try await settle(manager);manager.setEnabled(true);try await settle(manager)
        require(center.schedules.isEmpty && (preferences.dictionary(forKey:ResetReminderManager.preferencePrefix+"announced") ?? [:]).isEmpty,
                "Rejected notification operation must not persist a false delivered record")
        clock = origin.addingTimeInterval(31);center.scheduleError = nil;client.reply = .notModified
        manager.check(force:true);try await settle(manager)
        require(center.schedules.count == 1 && center.schedules[0].deliveryDate == nil,"An unchanged cached message must retry previously rejected delivery exactly once")
        print("Message delivery-failure tests passed: no false delivery record and later retry")
    }
    @MainActor static func independentMessageSettingsTests() async throws {
        let suite = "buddy-message-receiving-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let client = ResetFetchFixture(try document([event()]))
        let center = ResetCenterFixture()
        let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { manager.stop() }
        manager.start();try await settle(manager)
        require(manager.messagesEnabled && !manager.enabled && manager.panelAnnouncement(at:origin) != nil,
                "Messages default on without opting into system notifications")
        manager.setMessagesEnabled(false)
        manager.check(force:true);manager.tick(now:origin.addingTimeInterval(900))
        require(manager.upcoming == nil && client.requests.count == 1 && center.permissionRequests == 0,
                "Turning off receiving must hide messages and stop both forced and periodic fetches")
        manager.setEnabled(true);try await settle(manager)
        require(!manager.enabled && center.permissionRequests == 0 && center.schedules.isEmpty,
                "Push cannot be enabled or request permission while receiving is off")
        let restored = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { restored.stop() }
        restored.start();try await settle(restored)
        require(!restored.messagesEnabled && restored.upcoming == nil && client.requests.count == 1,
                "Restart must respect opt out without showing cached messages or fetching")
        restored.setMessagesEnabled(true);try await settle(restored)
        require(restored.messagesEnabled && restored.panelAnnouncement(at:origin) != nil && !restored.enabled &&
                client.requests.count == 2 && center.permissionRequests == 0,
                "Receiving resumes without requesting push permission")
        restored.setEnabled(true);try await settle(restored)
        require(restored.enabled && center.schedules.count == 1 && center.permissionRequests == 1,
                "Only opting into system notifications may request permission and push")
        restored.setMessagesEnabled(false);try await settle(restored)
        require(restored.enabled && restored.upcoming == nil && center.pending.isEmpty,
                "Opting out of messages stops push and remembers the user's push choice")
        let requests = client.requests.count
        let enabledRestore = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { enabledRestore.stop() }
        enabledRestore.start();enabledRestore.check(force:true);try await settle(enabledRestore)
        require(!enabledRestore.messagesEnabled && enabledRestore.enabled && client.requests.count == requests &&
                center.pending.isEmpty && center.permissionRequests == 1,
                "A saved push preference cannot override the receiving opt out on restart")
        enabledRestore.setMessagesEnabled(true);try await settle(enabledRestore)
        require(enabledRestore.panelAnnouncement(at:origin) != nil && center.schedules.count == 1 && center.permissionRequests == 1,
                "Resuming must not replay an already delivered message or ask for permission again")
        enabledRestore.setEnabled(false);try await settle(enabledRestore)
        require(enabledRestore.messagesEnabled && enabledRestore.panelAnnouncement(at:origin) != nil && center.pending.isEmpty,
                "Disabling push must retain received messages")
        preferences.removeObject(forKey:ResetReminderManager.preferencePrefix+"messagesEnabled")
        preferences.set(false,forKey:ResetReminderManager.preferencePrefix+"panelMessagesEnabled")
        let migrated = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { migrated.stop() }
        require(!migrated.messagesEnabled,"Preserve the previous preview's opt out when migrating its preference")
        let beforeDemo = preferences.persistentDomain(forName:suite) ?? [:]
        migrated.useDemo(now:origin);migrated.setMessagesEnabled(true)
        require(migrated.panelAnnouncement(at:origin) != nil &&
                NSDictionary(dictionary:beforeDemo).isEqual(NSDictionary(dictionary:preferences.persistentDomain(forName:suite) ?? [:])),
                "Synthetic preview choices must not change real preferences")
        print("Message receiving tests passed: master opt out, separate push consent, saved choices, restart, no replay and preview migration")
    }
    @MainActor static func activitySystemReminderTests() async throws {
        let suite = "buddy-activity-system-alerts-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let client = ResetFetchFixture(try document([])), center = ResetCenterFixture()
        let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { manager.stop() }
        let activity = ResetAnnouncement(id:"activity-synthetic",revision:1,type:"activity",status:.completed,
            publishedAt:origin,expiresAt:origin.addingTimeInterval(86_400),
            titleText:.init(zh:"合成活动",en:"Synthetic activity"),bodyText:.init(zh:"合成改进",en:"Synthetic improvement"),
            sourceURL:URL(string:"https://x.com/thsottiaux/status/123456")!,timestampBasis:.collected)
        manager.setResetMessagesEnabled(false);manager.setActivityMessages([activity]);manager.start();try await settle(manager)
        require(manager.panelAnnouncements(at:origin) == [activity] && client.requests.isEmpty && center.schedules.isEmpty,
                "Activity-only receipt displays content without reset fetches or push consent")
        manager.setEnabled(true);try await settle(manager)
        require(manager.enabled && center.permissionRequests == 1 && center.schedules.count == 1 && center.schedules[0].eventID == activity.id,
                "System alerts must support the selected activity type")
        manager.setActivityMessages([activity]);manager.tick(now:origin);try await settle(manager)
        require(center.schedules.count == 1,"Unchanged activity must not repeat its system alert")
        manager.setEnabled(false);try await settle(manager)
        require(manager.panelAnnouncements(at:origin) == [activity] && center.pending.isEmpty,
                "Disabling push keeps message receipt and display")
        manager.setEnabled(true);try await settle(manager)
        require(center.permissionRequests == 1 && center.schedules.count == 1,"Restore push without a new permission request or duplicate")
        let changed = ResetAnnouncement(id:activity.id,revision:2,type:"activity",status:.completed,
            publishedAt:origin,expiresAt:activity.expiresAt,titleText:activity.titleText,bodyText:.init(zh:"合成更正",en:"Synthetic correction"),
            sourceURL:activity.sourceURL,timestampBasis:.collected)
        manager.setActivityMessages([changed]);try await settle(manager)
        require(center.schedules.count == 2 && center.pending.count == 1,"A changed activity revision delivers once")
        manager.setResetMessagesEnabled(true);try await settle(manager)
        manager.setResetMessagesEnabled(false);try await settle(manager)
        require(manager.acceptsActivityMessages && center.pending.count == 1,"Turning reset reception off must retain selected activity alerts")
        manager.dismissPanelMessage(changed.id)
        require(manager.panelAnnouncements(at:origin).isEmpty,"Dismissal hides the message for this run")
        manager.setMessagesEnabled(false);try await settle(manager)
        require(manager.panelAnnouncements(at:origin).isEmpty && center.pending.isEmpty,"Message master stops both types and their push")
        manager.setMessagesEnabled(true);try await settle(manager)
        require(center.schedules.count == 2,"Restoring receipt does not replay an already delivered revision")
        print("Activity system alerts passed: shared content selection, independent push, revision dedupe and category cleanup")
    }
    @MainActor static func categorySettingsTests() async throws {
        let suite = "buddy-message-category-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let client = ResetFetchFixture(try document([event()])), center = ResetCenterFixture()
        let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { manager.stop() }
        manager.start();try await settle(manager)
        require(manager.resetMessagesEnabled && manager.activityMessagesEnabled,"Both categories default on for existing users")
        manager.setActivityMessagesEnabled(false)
        require(manager.panelAnnouncement(at:origin) != nil && manager.acceptsResetMessages && !manager.acceptsActivityMessages,
                "Disabling activity must not hide reset messages")
        manager.setResetMessagesEnabled(false);manager.check(force:true);try await settle(manager)
        require(manager.messagesEnabled && manager.upcoming == nil && client.requests.count == 1,
                "Reset opt out stops fetching without disabling the master")
        manager.setEnabled(true);try await settle(manager)
        require(center.permissionRequests == 0,"Reset opt out must not request push permission")
        manager.setActivityMessagesEnabled(true)
        require(manager.acceptsActivityMessages && !manager.acceptsResetMessages,"Activity works independently of reset reminders")
        manager.setMessagesEnabled(false)
        require(!manager.messagesEnabled && manager.activityMessagesEnabled && !manager.resetMessagesEnabled,
                "The master must still turn off while reset reminders are off and retain child choices")
        let restored = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { restored.stop() }
        restored.start();try await settle(restored)
        require(!restored.messagesEnabled && !restored.resetMessagesEnabled && restored.activityMessagesEnabled && client.requests.count == 1,
                "Restart preserves all three choices without fetching")
        restored.setMessagesEnabled(true);try await settle(restored)
        require(restored.acceptsActivityMessages && !restored.acceptsResetMessages && client.requests.count == 1,
                "Restoring master does not override disabled reset category")
        restored.setResetMessagesEnabled(true);try await settle(restored)
        require(restored.panelAnnouncement(at:origin) != nil && client.requests.count == 2 && center.permissionRequests == 0,
                "Reset reception resumes independently without push consent")
        preferences.removeObject(forKey:ResetReminderManager.preferencePrefix+"lastAttempt")
        let suspended = SuspendedResetFetchFixture()
        let cancellation = ResetReminderManager(preferences:preferences,client:suspended,notifications:center,now:{origin})
        defer { cancellation.stop() }
        cancellation.start();cancellation.check(force:true)
        for _ in 0..<200 where suspended.pending == nil { try await Task.sleep(nanoseconds:1_000_000) }
        require(suspended.pending != nil,"Category cancellation fixture must suspend a request")
        cancellation.setResetMessagesEnabled(false);suspended.complete(try document([event(id:"new-synthetic")]))
        try await settle(cancellation)
        require(cancellation.upcoming == nil,"Reset category opt out rejects in-flight delivery")
        print("Message categories passed: independent reception, saved choices, master gating, permission and cancellation")
    }
    @MainActor static func receivingCancellationTests() async throws {
        let suite = "buddy-message-cancel-receiving-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let client = SuspendedResetFetchFixture()
        let center = ResetCenterFixture()
        let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { manager.stop() }
        manager.start()
        for _ in 0..<200 where client.pending == nil { try await Task.sleep(nanoseconds:1_000_000) }
        require(client.pending != nil && manager.checking,"Suspend an actual message request")
        manager.setMessagesEnabled(false)
        client.complete(try document([event()]))
        try await settle(manager)
        require(manager.upcoming == nil && preferences.data(forKey:ResetReminderManager.preferencePrefix+"cache") == nil,
                "An in-flight fetch must not accept or cache messages after opt out")
        manager.setMessagesEnabled(true)
        for _ in 0..<200 where client.pending == nil { try await Task.sleep(nanoseconds:1_000_000) }
        require(client.requests == 2 && client.pending != nil,"Resume with a new request")
        client.complete(try document([event()]));try await settle(manager)
        require(manager.upcoming != nil && center.permissionRequests == 0,"Resuming receiving requires no push consent")

        let offlineSuite = "buddy-message-resume-offline-\(UUID().uuidString)"
        let offlinePreferences = UserDefaults(suiteName:offlineSuite)!
        defer { offlinePreferences.removePersistentDomain(forName:offlineSuite) }
        offlinePreferences.set(true,forKey:ResetReminderManager.preferencePrefix+"enabled")
        offlinePreferences.set(try document([event()]),forKey:ResetReminderManager.preferencePrefix+"cache")
        let offlineClient = ResetFetchFixture(try document([]));offlineClient.failure = URLError(.notConnectedToInternet)
        let allowedCenter = ResetCenterFixture();allowedCenter.permission = .allowed
        let offline = ResetReminderManager(preferences:offlinePreferences,client:offlineClient,notifications:allowedCenter,now:{origin})
        defer { offline.stop() }
        offline.start();offline.setMessagesEnabled(false);offline.setMessagesEnabled(true)
        try await settle(offline)
        require(offline.panelAnnouncement(at:origin) != nil && allowedCenter.schedules.count == 1 && allowedCenter.permissionRequests == 0,
                "Rapid opt out/in must replace canceled delivery work and honor prior push consent even offline")
        print("Receiving cancellation passed: stale fetch rejected, fresh resume and offline delivery recovery")
    }
    @MainActor static func panelDismissalTests() async throws {
        let suite = "buddy-message-panel-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let client = ResetFetchFixture(try document([event()]))
        let center = ResetCenterFixture();center.permission = .allowed
        let manager = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { manager.stop() }
        manager.check();try await settle(manager);manager.setEnabled(true);try await settle(manager)
        let announcement = manager.upcoming!
        require(manager.panelAnnouncement(at:origin) == announcement,"A no-deadline message must be available until expiry")
        let stored = preferences.persistentDomain(forName:suite) ?? [:]
        let pendingIDs = Set(center.pending.keys), schedules = center.schedules.count
        let removedPending = center.removedPending, removedDelivered = center.removedDelivered
        let removedAll = center.removeAllCount, authorizationChecks = center.authorizationChecks
        manager.dismissPanelAnnouncement();try await settle(manager)
        require(manager.panelAnnouncement(at:origin) == nil && manager.upcoming == announcement && manager.enabled,
                "Session close must hide only the panel row, retaining message and notification preference")
        require(NSDictionary(dictionary:stored).isEqual(NSDictionary(dictionary:preferences.persistentDomain(forName:suite) ?? [:])) &&
                Set(center.pending.keys) == pendingIDs && center.schedules.count == schedules && center.removedPending == removedPending &&
                center.removedDelivered == removedDelivered && center.removeAllCount == removedAll && center.authorizationChecks == authorizationChecks,
                "Panel close must not persist ignored IDs or mutate notification state")
        let restored = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{origin})
        defer { restored.stop() }
        require(restored.panelAnnouncement(at:origin)?.id == announcement.id && client.requests.count == 1,"New session must restore a valid cached row without another fetch")
        require(restored.panelAnnouncement(at:announcement.expiresAt.addingTimeInterval(-1)) != nil && restored.panelAnnouncement(at:announcement.expiresAt) == nil,
                "Message without deadline must stay visible until its exact expiry")
        let expired = ResetReminderManager(preferences:preferences,client:client,notifications:center,now:{announcement.expiresAt})
        defer { expired.stop() }
        require(expired.panelAnnouncement(at:announcement.expiresAt) == nil,"Expired message must not return on restart")
        let deadlineSuite = "buddy-message-panel-deadline-tests-\(UUID().uuidString)"
        let deadlinePreferences = UserDefaults(suiteName:deadlineSuite)!
        defer { deadlinePreferences.removePersistentDomain(forName:deadlineSuite) }
        let deadline = origin.addingTimeInterval(3_600)
        let bytes = try document([event(deadline:deadline)])
        deadlinePreferences.set(bytes,forKey:ResetReminderManager.preferencePrefix+"cache")
        let deadlineManager = ResetReminderManager(preferences:deadlinePreferences,client:ResetFetchFixture(bytes),notifications:ResetCenterFixture(),now:{origin})
        defer { deadlineManager.stop() }
        require(deadlineManager.panelAnnouncement(at:deadline.addingTimeInterval(-1)) != nil && deadlineManager.panelAnnouncement(at:deadline) == nil,
                "Optional message deadline must hide the row at its boundary, independently of expiry")
        let pastDeadline = ResetReminderManager(preferences:deadlinePreferences,client:ResetFetchFixture(bytes),notifications:ResetCenterFixture(),now:{deadline})
        defer { pastDeadline.stop() }
        require(pastDeadline.panelAnnouncement(at:deadline) == nil,"Restart must not resurrect an overdue message")
        let demoSuite = "buddy-message-demo-tests-\(UUID().uuidString)"
        let demoPreferences = UserDefaults(suiteName:demoSuite)!
        defer { demoPreferences.removePersistentDomain(forName:demoSuite) }
        let demoClient = ResetFetchFixture(try document([])), demoCenter = ResetCenterFixture()
        let demo = ResetReminderManager(preferences:demoPreferences,client:demoClient,notifications:demoCenter,now:{origin})
        defer { demo.stop() }
        demo.useDemo(now:origin)
        let demoStored = demoPreferences.persistentDomain(forName:demoSuite) ?? [:]
        demo.dismissPanelAnnouncement();require(demo.panelAnnouncement(at:origin) == nil,"Synthetic panel supports session dismissal")
        demo.useDemo(now:origin)
        require(demo.panelAnnouncement(at:origin)?.type == "message","New synthetic scene must reset dismissal and use the generic message path")
        demo.useDemo(now:origin,status:nil);require(demo.panelAnnouncement(at:origin) == nil,"Empty synthetic scene must remain empty")
        require(NSDictionary(dictionary:demoStored).isEqual(NSDictionary(dictionary:demoPreferences.persistentDomain(forName:demoSuite) ?? [:])) &&
                demoClient.requests.isEmpty && demoCenter.permissionRequests == 0 && demoCenter.authorizationChecks == 0 && demoCenter.schedules.isEmpty,
                "Demo must not change real preferences, fetch, prompt or notify")
        print("Message panel tests passed: session-only close, restart restore, optional deadline/expiry and demo isolation")
    }
}
