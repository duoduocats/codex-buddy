import Foundation

private final class ChallengePreferences: UserDefaults {
    var values: [String:Any] = [:]
    override func object(forKey key:String) -> Any? { values[key] }
    override func set(_ value:Any?,forKey key:String) { values[key] = value }
    override func data(forKey key:String) -> Data? { values[key] as? Data }
    override func string(forKey key:String) -> String? { values[key] as? String }
}
private final class ChallengeFixture: ResetAnnouncementFetching {
    var calls = 0
    var delay = false
    var fail = false
    var notPublished = false
    var data: Data
    var tags: [String?] = []
    init(_ data: Data) { self.data = data }
    func fetch(etag: String?) async throws -> ResetFetchResult {
        calls += 1;tags.append(etag)
        if delay { try await Task.sleep(nanoseconds:1_000_000_000) }
        if fail { throw ResetAnnouncementFailure.network }
        if notPublished { throw ResetAnnouncementFailure.notPublished }
        return .document(data,etag:"\"synthetic\"")
    }
}
private final class ChallengeHTTPFixture: URLProtocol {
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url == TiboChallengeDocument.feedURL)
        precondition(request.value(forHTTPHeaderField:"Authorization") == nil && request.value(forHTTPHeaderField:"Cookie") == nil)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:404,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct ChallengeTests {
    @MainActor static func main() async throws {
        let now = ISO8601DateFormatter().date(from:"2026-10-06T02:15:00Z")!
        let fixture = #"{"schemaVersion":1,"id":"tibo-28-2026-10-05","revision":2,"startDate":"2026-10-05","days":28,"timeZone":"America/Los_Angeles","sourceURL":"https://x.com/thsottiaux/status/123456","title":{"zh":"合成活动","en":"Synthetic activity"},"statement":{"zh":"仅供测试","en":"Synthetic test only"},"records":[{"id":"synthetic-record","revision":1,"day":1,"kind":"improvement","status":"completed","title":{"zh":"测试改进","en":"Synthetic improvement"},"body":{"zh":"测试内容","en":"Synthetic content"},"sourceURL":"https://x.com/thsottiaux/status/234567","collectedAt":"2026-10-06T01:00:00Z"}]}"#
        let bytes = Data(fixture.utf8)
        let document = try TiboChallengeDocument.decode(bytes,now:now)
        precondition(document.currentDay(at:now) == 1,"Days must follow Pacific, not the user's October 6 date")
        precondition(document.isActive(at:document.start) && !document.isActive(at:document.end))
        precondition(ISO8601DateFormatter().string(from:document.end) == "2026-11-02T08:00:00Z","The end must cross DST using calendar days")
        precondition(document.currentDay(at:document.start.addingTimeInterval(-1)) == 0)
        precondition(document.records(for:28).isEmpty,"No future successes may be invented")
        for replacement in [
            ("\"days\":28","\"days\":29"), ("America/Los_Angeles","Asia/Shanghai"),
            ("\"day\":1","\"day\":29"), ("/thsottiaux/","/somebodyelse/"),
            ("\"status\":\"completed\"","\"status\":\"scheduled\""),
            ("2026-10-06T01:00:00Z","2026-10-06T01:00:00+00:00"),
            ("2026-10-06T01:00:00Z","2026-10-07T01:00:00Z")
        ] {
            do { _ = try TiboChallengeDocument.decode(Data(fixture.replacingOccurrences(of:replacement.0,with:replacement.1).utf8),now:now);fatalError("Invalid feed accepted") }
            catch { }
        }
        do { _ = try TiboChallengeDocument.decode(Data(repeating:32,count:TiboChallengeDocument.maximumBytes+1),now:now);fatalError("Oversize feed accepted") } catch { }
        let editedSameRevision = try TiboChallengeDocument.decode(Data(fixture.replacingOccurrences(of:"Synthetic content",with:"Changed content").utf8),now:now)
        precondition(!document.accepts(editedSameRevision),"Changed content requires a revision bump")
        let correctedBytes = Data(fixture.replacingOccurrences(of:"\"revision\":2",with:"\"revision\":3").replacingOccurrences(of:"\"revision\":1",with:"\"revision\":2").replacingOccurrences(of:"Synthetic content",with:"Changed content").utf8)
        let corrected = try TiboChallengeDocument.decode(correctedBytes,now:now)
        precondition(document.accepts(corrected) && !corrected.accepts(document),"Revisions cannot roll back")
        let seed = try TiboChallengeDocument.decode(Data(fixture.replacingOccurrences(of:"\"revision\":2",with:"\"revision\":1").utf8),now:now)
        let preferences = ChallengePreferences(), client = ChallengeFixture(bytes)
        let manager = TiboChallengeManager(preferences:preferences,enabled:false,client:client,initialDocument:seed,now:{now})
        manager.start();manager.check(force:true)
        precondition(client.calls == 0,"Disabled messages must not fetch challenge data")
        manager.setEnabled(true)
        await wait(manager)
        precondition(client.calls == 1 && manager.document == document)
        manager.check();await wait(manager)
        precondition(client.calls == 1,"Polling must be bounded")
        let cached = TiboChallengeManager(preferences:preferences,client:client,initialDocument:seed,now:{now})
        precondition(cached.document == document,"Restart must preserve the valid cache")
        manager.stop();client.delay = true
        let pending = TiboChallengeManager(preferences:ChallengePreferences(),client:client,initialDocument:seed,now:{now})
        pending.start();try await Task.sleep(nanoseconds:5_000_000)
        var closed = false;pending.onDisabled = { closed = true };pending.setEnabled(false)
        try await Task.sleep(nanoseconds:10_000_000)
        precondition(closed && !pending.checking && pending.document == seed,"Disable cancels in-flight writes and closes activity")
        client.delay = false;client.fail = true
        cached.start();await wait(cached)
        precondition(cached.document == document && cached.error != nil,"Failures retain the verified history")
        cached.stop();pending.stop()
        client.fail = false;client.notPublished = true
        let bootstrap = TiboChallengeManager(preferences:ChallengePreferences(),client:client,initialDocument:seed,now:{now})
        bootstrap.start();await wait(bootstrap)
        precondition(bootstrap.error == nil && bootstrap.document == seed,"Before the first feed is published, the saved baseline is normal")
        bootstrap.stop()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChallengeHTTPFixture.self]
        configuration.httpAdditionalHeaders = ["Authorization":"Bearer synthetic-challenge-only", "Cookie":"synthetic=1"]
        let publicClient = ResetAnnouncementClient(configuration:configuration,feedURL:TiboChallengeDocument.feedURL,maximumBytes:TiboChallengeDocument.maximumBytes)
        do { _ = try await publicClient.fetch(etag:nil);fatalError("Missing campaign feed should be a distinct bootstrap condition") }
        catch ResetAnnouncementFailure.notPublished { }
        let message = ResetAnnouncement(id:"synthetic-message",revision:1,type:"message",status:.completed,
            publishedAt:now,expiresAt:now.addingTimeInterval(86_400),titleText:.init(zh:"测试",en:"Synthetic"),
            bodyText:.init(zh:"测试",en:"Synthetic"),timestampBasis:.collected)
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let decoded = try ResetAnnouncementDocument.decode(encoder.encode(ResetAnnouncementDocument(schemaVersion:1,events:[message])),now:now)
        precondition(decoded.events[0].timestampBasis == .collected)
        let text = decoded.events[0].timeDescription()
        precondition(text.hasPrefix("收录时间") || text.hasPrefix("Collected"),"Collection time must be labelled honestly")
        precondition(message.scheduledAt == nil,"An unknown publication time adds no reset countdown")
        print("Challenge checks passed: Pacific calendar, DST, revisions, sources, cache, cancellation and collection times")
    }
    @MainActor private static func wait(_ manager: TiboChallengeManager) async {
        for _ in 0..<200 where manager.checking { try? await Task.sleep(nanoseconds:1_000_000) }
        precondition(!manager.checking,"Fixture request did not finish")
    }
}
