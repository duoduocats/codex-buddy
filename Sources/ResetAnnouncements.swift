import Foundation

struct ResetLocalizedText: Codable, Equatable {
    let zh: String
    let en: String
    var localized: String { L(zh,en) }
}
enum ResetTimestampBasis: String, Codable { case source, collected }
enum ResetAnnouncementStatus: String, Codable { case scheduled, completed, cancelled }
struct ResetAnnouncement: Codable, Equatable, Identifiable {
    let id: String
    let revision: Int
    let type: String
    let status: ResetAnnouncementStatus
    let scheduledAt: Date?
    let publishedAt: Date
    let expiresAt: Date
    let timestampBasis: ResetTimestampBasis
    let titleText: ResetLocalizedText
    let bodyText: ResetLocalizedText
    let appliesToText: ResetLocalizedText?
    let sourceURL: URL?
    var title: String { titleText.localized }
    var body: String { bodyText.localized }
    var appliesTo: String { appliesToText?.localized ?? "" }
    var statusTitle: String {
        if type == "message" { return L("消息", "Message") }
        switch status {
        case .scheduled: return L("预计全球重置", "Expected global reset")
        case .completed: return L("官方已确认执行", "Officially confirmed complete")
        case .cancelled: return L("重置计划已取消", "Reset cancelled")
        }
    }
    var dateText: String {
        scheduledDateText() ?? statusTitle
    }
    func scheduledDateText(locale: Locale = .autoupdatingCurrent,
                           timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard let scheduledAt else { return nil }
        return Self.localDateText(for:scheduledAt,locale:locale,timeZone:timeZone)
    }
    func publishedDateText(locale: Locale = .autoupdatingCurrent,
                           timeZone: TimeZone = .autoupdatingCurrent) -> String {
        Self.localDateText(for:publishedAt,locale:locale,timeZone:timeZone)
    }
    func timeDescription(locale: Locale = .autoupdatingCurrent,
                         timeZone: TimeZone = .autoupdatingCurrent) -> String {
        if let scheduled = scheduledDateText(locale:locale,timeZone:timeZone) {
            return L("预计时间：\(scheduled)", "Expected time: \(scheduled)")
        }
        let published = publishedDateText(locale:locale,timeZone:timeZone)
        return timestampBasis == .collected
            ? L("收录时间：\(published)", "Collected: \(published)")
            : L("发布时间：\(published)", "Published: \(published)")
    }
    private static func localDateText(for date: Date, locale: Locale, timeZone: TimeZone) -> String {
        // Create a formatter per presentation so locale, hour cycle and time zone
        // changes are reflected when the panel refreshes while the app is running.
        let formatter = DateFormatter();formatter.locale = locale;formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmmz")
        return formatter.string(from:date)
    }
    enum CodingKeys: String, CodingKey {
        case id, revision, type, status, scheduledAt, publishedAt, expiresAt, sourceURL, timestampBasis
        case titleText = "title", bodyText = "body", appliesToText = "appliesTo"
    }
    init(id: String, revision: Int, type: String, status: ResetAnnouncementStatus = .scheduled,
         scheduledAt: Date? = nil, publishedAt: Date, expiresAt: Date,
         titleText: ResetLocalizedText, bodyText: ResetLocalizedText,
         appliesToText: ResetLocalizedText? = nil, sourceURL: URL? = nil, timestampBasis: ResetTimestampBasis = .source) {
        self.id = id;self.revision = revision;self.type = type;self.status = status
        self.scheduledAt = scheduledAt;self.publishedAt = publishedAt;self.expiresAt = expiresAt;self.timestampBasis = timestampBasis
        self.titleText = titleText;self.bodyText = bodyText;self.appliesToText = appliesToText;self.sourceURL = sourceURL
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        id = try values.decode(String.self,forKey:.id)
        revision = try values.decode(Int.self,forKey:.revision)
        type = try values.decode(String.self,forKey:.type)
        status = try values.decodeIfPresent(ResetAnnouncementStatus.self,forKey:.status) ?? .scheduled
        scheduledAt = try values.decodeIfPresent(Date.self,forKey:.scheduledAt)
        publishedAt = try values.decode(Date.self,forKey:.publishedAt)
        expiresAt = try values.decode(Date.self,forKey:.expiresAt)
        timestampBasis = try values.decodeIfPresent(ResetTimestampBasis.self,forKey:.timestampBasis) ?? .source
        titleText = try values.decode(ResetLocalizedText.self,forKey:.titleText)
        bodyText = try values.decode(ResetLocalizedText.self,forKey:.bodyText)
        appliesToText = try values.decodeIfPresent(ResetLocalizedText.self,forKey:.appliesToText)
        sourceURL = try values.decodeIfPresent(URL.self,forKey:.sourceURL)
    }
}
struct ResetAnnouncementDocument: Codable {
    static let maximumBytes = 65_536
    let schemaVersion: Int
    let events: [ResetAnnouncement]
    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ResetAnnouncementFailure.invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard text.count <= 32, text.hasSuffix("Z") else { throw ResetAnnouncementFailure.invalid }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from:text) ?? ISO8601DateFormatter().date(from:text)
            guard let date, date.timeIntervalSince1970.isFinite else { throw ResetAnnouncementFailure.invalid }
            return date
        }
        let document = try decoder.decode(Self.self,from:data)
        guard document.schemaVersion == 1, document.events.count <= 50,
              Set(document.events.map(\.id)).count == document.events.count else { throw ResetAnnouncementFailure.invalid }
        for event in document.events {
            guard validID(event.id), (1...1_000_000).contains(event.revision), ["message","globalReset"].contains(event.type),
                  event.publishedAt.timeIntervalSince1970 >= 1_577_836_800,
                  event.publishedAt <= now,
                  event.expiresAt > event.publishedAt,
                  event.expiresAt.timeIntervalSince(event.publishedAt) <= 366*86_400,
                  validText(event.titleText,maximum:160), validText(event.bodyText,maximum:1_000) else { throw ResetAnnouncementFailure.invalid }
            if let source = event.sourceURL, !validSourceURL(source) { throw ResetAnnouncementFailure.invalid }
            if let audience = event.appliesToText, !validText(audience,maximum:300) { throw ResetAnnouncementFailure.invalid }
            if event.type == "globalReset", event.sourceURL == nil || event.appliesToText == nil { throw ResetAnnouncementFailure.invalid }
            if let date = event.scheduledAt {
                guard date >= event.publishedAt.addingTimeInterval(-30*86_400),
                      date <= event.publishedAt.addingTimeInterval(366*86_400), date <= event.expiresAt else { throw ResetAnnouncementFailure.invalid }
            } else if event.type == "globalReset", event.status == .scheduled { throw ResetAnnouncementFailure.invalid }
        }
        return document
    }
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || $0 == "-" || $0 == "_"
        }
    }
    static func validSourceURL(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 500, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              !url.absoluteString.contains("%"), let host = url.host?.lowercased() else { return false }
        let parts = url.path.split(separator:"/",omittingEmptySubsequences:true)
        if ["x.com","twitter.com"].contains(host) {
            return parts.count == 3 && ["thsottiaux","openai","chatgpt"].contains(parts[0].lowercased()) && parts[1] == "status" &&
                !parts[2].isEmpty && parts[2].count <= 25 && parts[2].allSatisfy { $0.isASCII && $0.isNumber }
        }
        if host == "github.com" {
            guard parts.count >= 3, url.path == "/"+parts.joined(separator:"/"),
                  parts[0] == "duoduocats", parts[1] == "codex-buddy" else { return false }
            if parts[2] == "issues" {
                return parts.count == 4 && !parts[3].isEmpty && parts[3].count <= 20 && parts[3].allSatisfy { $0.isASCII && $0.isNumber }
            }
            if parts[2] == "releases" {
                return parts.count == 3 || (parts.count == 5 && parts[3] == "tag" && validPathComponent(parts[4]))
            }
            return parts.count >= 5 && parts[2] == "blob" && parts[3] == "main" && parts[4] == "docs" &&
                parts.count >= 6 && parts.dropFirst(5).allSatisfy(validPathComponent)
        }
        return ["openai.com","help.openai.com","status.openai.com","chatgpt.com"].contains(host) && !parts.isEmpty
    }
    private static func validPathComponent(_ part: Substring) -> Bool {
        !part.isEmpty && part != "." && part != ".." && part.utf8.count <= 120 && part.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || "-_.".unicodeScalars.contains($0)
        }
    }
    static func validText(_ text: ResetLocalizedText, maximum: Int) -> Bool {
        [text.zh,text.en].allSatisfy {
            !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count <= maximum &&
            !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }
        }
    }
}
enum ResetAnnouncementFailure: Error { case invalid, network, notPublished, retryAfter(Date) }
enum PublicFeedRefreshPolicy {
    static func interval(failures: Int) -> TimeInterval {
        [300,60,300,900,3_600][min(4,max(0,failures))]
    }
    static func connectionFailed(_ error: Error) -> Bool {
        if case ResetAnnouncementFailure.network = error { return true }
        return error is URLError
    }
}
enum ResetFetchResult {
    case notModified
    case document(Data, etag: String?)
}
protocol ResetAnnouncementFetching {
    func fetch(etag: String?) async throws -> ResetFetchResult
    func fetchFresh(etag: String?) async throws -> ResetFetchResult
    func retainCachedData(_ data: Data)
    var retryNotBefore: Date? { get }
}
extension ResetAnnouncementFetching {
    var retryNotBefore: Date? { nil }
    func fetchFresh(etag: String?) async throws -> ResetFetchResult { try await fetch(etag:etag) }
    func retainCachedData(_ data: Data) { }
}
private final class ResetFeedRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let endpoints: Set<URL>
    init(endpoints: Set<URL>) { self.endpoints = endpoints }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(task.originalRequest?.url == request.url && request.url.map(endpoints.contains) == true ? request : nil)
    }
}
final class ResetAnnouncementClient: ResetAnnouncementFetching {
    static let feedURL = URL(string:"https://raw.githubusercontent.com/duoduocats/codex-buddy/main/announcements/messages.json")!
    private let session: URLSession
    private let endpoint: URL
    private let fallback: URL
    private let maximumBytes: Int
    private let clock: () -> Date
    private let validate: ((Data) throws -> Void)?
    private var endpointNotBefore: [URL:Date] = [:]
    private var cachedData: Data?
    private var lastRawProbe: Date?
    private(set) var retryNotBefore: Date?
    init(configuration: URLSessionConfiguration = .ephemeral, feedURL: URL = ResetAnnouncementClient.feedURL,
         maximumBytes: Int = ResetAnnouncementDocument.maximumBytes, now: @escaping () -> Date = { Date() },
         validate: ((Data) throws -> Void)? = nil) {
        precondition([Self.feedURL,URL(string:"https://raw.githubusercontent.com/duoduocats/codex-buddy/main/announcements/tibo-28.json")!].contains(feedURL))
        precondition((1...131_072).contains(maximumBytes))
        self.endpoint = feedURL;self.maximumBytes = maximumBytes;self.clock = now;self.validate = validate
        fallback = URL(string:"https://api.github.com/repos/duoduocats/codex-buddy/contents/announcements/"+feedURL.lastPathComponent+"?ref=main")!
        configuration.timeoutIntervalForRequest = 10;configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil;configuration.httpCookieStorage = nil;configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false;configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [:]
        session = URLSession(configuration:configuration,delegate:ResetFeedRedirectDelegate(endpoints:[feedURL,fallback]),delegateQueue:nil)
    }
    deinit { session.invalidateAndCancel() }
    static func validETag(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    func fetch(etag: String?) async throws -> ResetFetchResult {
        let primary = etag?.hasPrefix("api:") == true ? fallback : endpoint
        return try await fetch(primary:primary,etag:etag)
    }
    func fetchFresh(etag: String?) async throws -> ResetFetchResult {
        // A user opening records verifies the canonical branch through the other
        // official origin even when an intermediary keeps returning an old 304.
        let primary = endpointNotBefore[fallback].map { $0 > clock() } == true ? endpoint : fallback
        return try await fetch(primary:primary,etag:etag)
    }
    func retainCachedData(_ data: Data) { cachedData = data }
    private func fetch(primary: URL, etag: String?) async throws -> ResetFetchResult {
        retryNotBefore = nil
        do {
            let result = try await fetch(from:primary,scope:primary == endpoint ? "raw:" : "api:",etag:etag)
            if primary == fallback, case .notModified = result, let cachedData,
               lastRawProbe.map({ clock().timeIntervalSince($0) >= 3_600 }) ?? true {
                lastRawProbe = clock()
                let serverDelay = retryNotBefore
                do {
                    let probe = try await fetch(from:endpoint,scope:"raw:",etag:nil)
                    if case .document(let bytes,_) = probe, bytes == cachedData {
                        retryNotBefore = nil;return probe
                    }
                } catch { }
                retryNotBefore = serverDelay
            }
            return result
        }
        catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if case ResetAnnouncementFailure.invalid = error { throw error }
            if case ResetAnnouncementFailure.retryAfter = error { throw error }
            let secondary = primary == endpoint ? fallback : endpoint
            return try await fetch(from:secondary,scope:secondary == endpoint ? "raw:" : "api:",etag:etag)
        }
    }
    private func tag(_ token: String?, scope: String) -> String? {
        guard let token = Self.validETag(token) else { return nil }
        if token.hasPrefix(scope) { return Self.validETag(String(token.dropFirst(scope.count))) }
        if token.hasPrefix("raw:") || token.hasPrefix("api:") { return nil }
        return scope == "raw:" ? token : nil // Existing caches used a raw-source validator.
    }
    private func fetch(from url: URL, scope: String, etag: String?) async throws -> ResetFetchResult {
        if let date = endpointNotBefore[url], date > clock() { throw ResetAnnouncementFailure.retryAfter(date) }
        var request = URLRequest(url:url)
        request.setValue(scope == "api:" ? "application/vnd.github.raw+json" : "application/json",forHTTPHeaderField:"Accept")
        // A fixed identifier contains no installed version or machine/account information.
        request.setValue("Codex-Buddy-Announcements",forHTTPHeaderField:"User-Agent")
        if let value = tag(etag,scope:scope) { request.setValue(value,forHTTPHeaderField:"If-None-Match") }
        let (bytes,response) = try await session.bytes(for:request)
        guard let response = response as? HTTPURLResponse, response.url == url else { throw ResetAnnouncementFailure.invalid }
        if response.statusCode == 429 || response.statusCode >= 400 &&
            (response.value(forHTTPHeaderField:"X-RateLimit-Remaining") == "0" || response.value(forHTTPHeaderField:"Retry-After") != nil) {
            let retry = Self.retryDate(response,now:clock()) ?? clock().addingTimeInterval(60)
            endpointNotBefore[url] = retry
            throw ResetAnnouncementFailure.retryAfter(retry)
        }
        if response.value(forHTTPHeaderField:"X-RateLimit-Remaining") == "0", let date = Self.retryDate(response,now:clock()) {
            endpointNotBefore[url] = date;retryNotBefore = date
        }
        if response.statusCode == 304 {
            guard tag(etag,scope:scope) != nil else { throw ResetAnnouncementFailure.network }
            return .notModified
        }
        if response.statusCode == 404, endpoint.lastPathComponent == "tibo-28.json" { throw ResetAnnouncementFailure.notPublished }
        guard response.statusCode == 200,
              response.expectedContentLength <= Int64(maximumBytes) else { throw ResetAnnouncementFailure.network }
        var data = Data();data.reserveCapacity(4_096)
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw ResetAnnouncementFailure.invalid }
            data.append(byte)
        }
        guard !data.isEmpty else { throw ResetAnnouncementFailure.invalid }
        guard let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              object["schemaVersion"] != nil,
              object[endpoint.lastPathComponent == "messages.json" ? "events" : "records"] is [Any] else {
            throw ResetAnnouncementFailure.network
        }
        do { try validate?(data) } catch { throw ResetAnnouncementFailure.network }
        let scopedTag = Self.validETag(response.value(forHTTPHeaderField:"ETag")).flatMap { Self.validETag(scope+$0) }
        return .document(data,etag:scopedTag)
    }
    static func retryDate(_ response: HTTPURLResponse, now: Date) -> Date? {
        if let text = response.value(forHTTPHeaderField:"Retry-After") {
            if let seconds = TimeInterval(text), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
            let formatter = DateFormatter();formatter.locale = Locale(identifier:"en_US_POSIX");formatter.timeZone = TimeZone(secondsFromGMT:0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from:text) { return date }
        }
        if let text = response.value(forHTTPHeaderField:"X-RateLimit-Reset"), let seconds = TimeInterval(text), seconds.isFinite {
            return Date(timeIntervalSince1970:seconds)
        }
        return nil
    }
}
