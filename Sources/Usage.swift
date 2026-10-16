import Foundation
import CryptoKit

struct LimitWindow: Codable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var resetDate: Date? {
        guard let timestamp = resetsAt, timestamp.isFinite,
              (-62135596800...253402300799).contains(timestamp) else { return nil }
        return Date(timeIntervalSince1970:timestamp)
    }
    var label: String {
        guard let minutes = windowDurationMins else { return L("额度", "Usage limit") }
        if minutes == 10080 { return L("每周额度", "Weekly limit") }
        if minutes >= 1440 { return L("\(minutes / 1440) 天额度", "\(minutes / 1440)-day limit") }
        if minutes >= 60 { return L("\(minutes / 60) 小时额度", "\(minutes / 60)-hour limit") }
        return L("\(minutes) 分钟额度", "\(minutes)-minute limit")
    }
    func detailCountdown(now: Date = Date()) -> String {
        guard let date = resetDate else { return "—" }
        let seconds = date.timeIntervalSince(now)
        guard seconds.isFinite else { return "—" }
        if seconds <= 0 { return "0h" }
        if seconds < 3600 { return "<1h" }
        let hours = Int(floor(seconds / 3600))
        return hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h"
    }
    func countdown(now: Date = Date()) -> String {
        guard let date = resetDate, date.timeIntervalSince1970.isFinite else { return "—" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "0m" }
        guard seconds.isFinite, seconds < Double(Int.max) else { return "—" }
        if seconds >= 86400 { return "\(Int(floor(seconds / 86400)))d" }
        if seconds >= 3600 { return "\(Int(floor(seconds / 3600)))h" }
        return "\(max(1, Int(ceil(seconds / 60))))m"
    }
}

struct LimitBucket: Codable, Equatable {
    let limitId: String?
    let limitName: String?
    let primary: LimitWindow?
    let secondary: LimitWindow?
    let planType: String?
    var windows: [LimitWindow] { [primary, secondary].compactMap { $0 } }
}
struct ResetCredits: Codable, Equatable { let availableCount: Int }

struct ResetCredit: Equatable {
    let expiresAt: Date?
    var expiryKnown = true
}

struct ResetCreditGroup: Equatable, Identifiable {
    let expiresAt: Date?
    let expiryKnown: Bool
    var count: Int
    var id: String { expiresAt.map { String($0.timeIntervalSince1970) } ?? (expiryKnown ? "no-expiry" : "unknown") }
}

struct ResetCreditDetails: Equatable {
    let availableCount: Int
    let credits: [ResetCredit]

    func groups(now:Date,onlySoonest:Bool) -> [ResetCreditGroup] {
        var grouped = [String:ResetCreditGroup]()
        for credit in credits where credit.expiresAt.map({ $0 > now }) ?? true {
            let row = ResetCreditGroup(expiresAt:credit.expiresAt,expiryKnown:credit.expiryKnown,count:1)
            if grouped[row.id] != nil { grouped[row.id]!.count += 1 }
            else { grouped[row.id] = row }
        }
        var values = Array(grouped.values)
        values.sort {
            if let first = $0.expiresAt,let second = $1.expiresAt { return first < second }
            if $0.expiresAt != nil { return true }
            if $1.expiresAt != nil { return false }
            return $0.expiryKnown && !$1.expiryKnown
        }
        return onlySoonest ? Array(values.filter { $0.expiresAt != nil }.prefix(1)) : values
    }

    func groupsExpiring(now:Date,withinDays:Int,calendar:Calendar = .autoupdatingCurrent) -> [ResetCreditGroup] {
        guard (1...30).contains(withinDays), let end = calendar.date(byAdding:.day,value:withinDays,to:now) else { return [] }
        return groups(now:now,onlySoonest:false).filter { group in
            guard let expiry = group.expiresAt else { return false }
            return expiry > now && expiry <= end
        }
    }

    static func decode(_ data:Data) throws -> Self {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let count = root["available_count"] as? Int, (0...100_000).contains(count),
              let rows = root["credits"] as? [[String:Any]],rows.count <= 1_024 else { throw UsageFailure.malformed }
        let standard = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter();fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        var seen = Set<String>(),credits = [ResetCredit]()
        for row in rows where row["status"] as? String == "available" && row["reset_type"] as? String == "codex_rate_limits" {
            guard let id = row["id"] as? String,!id.isEmpty,id.utf8.count <= 256,seen.insert(id).inserted else { throw UsageFailure.malformed }
            let expiry: Date?
            if let text = row["expires_at"] as? String {
                guard let date = fractional.date(from:text) ?? standard.date(from:text),
                      (-62135596800...253402300799).contains(date.timeIntervalSince1970) else { throw UsageFailure.malformed }
                expiry = date
            } else if row["expires_at"] == nil || row["expires_at"] is NSNull {
                expiry = nil
            } else { throw UsageFailure.malformed }
            // Only keep expiry information; profile fields and opaque IDs are discarded.
            credits.append(.init(expiresAt:expiry,expiryKnown:row["expires_at"] != nil))
        }
        guard credits.count <= count else { throw UsageFailure.malformed }
        return .init(availableCount:count,credits:credits)
    }

    static func demo(now:Date,count:Int = 2) -> Self {
        let credits = (0..<max(0,min(count,8))).map { index in
            ResetCredit(expiresAt:now.addingTimeInterval(index == 0 ? 172_800 : 604_800))
        }
        return .init(availableCount:credits.count,credits:credits)
    }
}
struct UsageResponse: Codable, Equatable {
    let rateLimits: LimitBucket?
    let rateLimitsByLimitId: [String: LimitBucket]?
    let rateLimitResetCredits: ResetCredits?
    var buckets: [(String, LimitBucket)] {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            return map.sorted { a, b in
                if a.key != b.key {
                    if a.key == "codex" { return true }; if b.key == "codex" { return false }
                }
                return a.key < b.key
            }.map { ($0.key, $0.value) }
        }
        return rateLimits.map { [($0.limitId ?? "codex", $0)] } ?? []
    }
    static var demo: UsageResponse {
        UsageResponse(rateLimits: LimitBucket(limitId: "codex", limitName: nil,
            primary: LimitWindow(usedPercent: 45, windowDurationMins: 10080, resetsAt: Date().addingTimeInterval(396000).timeIntervalSince1970),
            secondary:nil, planType: "test"),
            rateLimitsByLimitId: nil, rateLimitResetCredits: ResetCredits(availableCount: 2))
    }
}

enum UsageFailure: LocalizedError {
    case authentication, timeout, unavailable, malformed
    var errorDescription: String? {
        switch self {
        case .authentication: return L("请在 ChatGPT / Codex 中登录或刷新登录状态，然后重试。", "Sign in to ChatGPT / Codex or refresh your login, then try again.")
        case .timeout: return L("查询超时，请检查网络后重试。", "Request timed out. Check your connection and try again.")
        case .unavailable: return L("暂时无法读取额度，请稍后刷新。", "Usage is unavailable. Try refreshing later.")
        case .malformed: return L("暂时无法识别服务返回的数据。", "The service returned an unrecognized response.")
        }
    }
}

struct UsageReadSnapshot {
    let response: UsageResponse
    // Local salted partition only; never an account identifier or credential.
    let accountKey: String?
}
struct UsageStatisticsReadSnapshot {
    let response: UsageStatistics
    let accountKey: String?
}
struct ResetCreditsReadSnapshot {
    let response: ResetCreditDetails
    let accountKey: String?
}

// No helper process, credential persistence, redirects, cookies or response cache.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    var petTransfer: ((Int64,Bool)->Void)?
    private var recordedPets=Set<Int>()
    private func report(_ task:URLSessionTask,bytes:Int64,complete:Bool) {
        guard task.originalRequest?.url?.path == "/backend-api/pets",!recordedPets.contains(task.taskIdentifier) else { return }
        recordedPets.insert(task.taskIdentifier)
        if recordedPets.count > 128 { recordedPets=Set(recordedPets.sorted().suffix(64)) }
        petTransfer?(bytes,complete)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didFinishCollecting metrics:URLSessionTaskMetrics) {
        var bytes:Int64=0,complete=true
        for item in metrics.transactionMetrics where item.resourceFetchType == .networkLoad {
            for count in [item.countOfRequestHeaderBytesSent,item.countOfRequestBodyBytesSent,item.countOfResponseHeaderBytesReceived,item.countOfResponseBodyBytesReceived] {
                if count < 0 { complete=false } else { let sum=bytes.addingReportingOverflow(count);bytes=sum.overflow ? Int64.max : sum.partialValue }
            }
        }
        report(task,bytes:bytes,complete:complete)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        let sum=max(0,task.countOfBytesReceived).addingReportingOverflow(max(0,task.countOfBytesSent))
        report(task,bytes:sum.overflow ? Int64.max : sum.partialValue,complete:false)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor final class UsageClient {
    private let delegate = NoRedirect()
    private let credentialProvider: () -> Data?
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral, credentialProvider: (() -> Data?)? = nil, petTransfer: ((Int64,Bool)->Void)? = nil) {
        delegate.petTransfer=petTransfer
        self.configuration = configuration
        self.credentialProvider = credentialProvider ?? {
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath:$0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            return try? Data(contentsOf:home.appendingPathComponent("auth.json"))
        }
    }
    private lazy var session: URLSession = {
        let config = configuration
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.urlCache = nil; config.httpCookieStorage = nil;config.httpShouldSetCookies=false;config.urlCredentialStorage=nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration:config,delegate:delegate,delegateQueue:nil)
    }()
    func read() async throws -> UsageResponse {
        try Self.decode(await request(path:"/backend-api/wham/usage").data)
    }
    func readForForecast(identitySalt: Data) async throws -> UsageReadSnapshot {
        let result = try await request(path:"/backend-api/wham/usage", identitySalt:identitySalt)
        return UsageReadSnapshot(response:try Self.decode(result.data),accountKey:result.accountKey)
    }
    func readStatistics() async throws -> UsageStatistics {
        try UsageStatistics.decode(await request(path:"/backend-api/wham/profiles/me").data)
    }
    func readResetCredits() async throws -> ResetCreditDetails {
        try ResetCreditDetails.decode(await request(path:"/backend-api/wham/rate-limit-reset-credits").data)
    }
    func readStatisticsWithContext(identitySalt: Data) async throws -> UsageStatisticsReadSnapshot {
        let result=try await request(path:"/backend-api/wham/profiles/me",identitySalt:identitySalt)
        return UsageStatisticsReadSnapshot(response:try UsageStatistics.decode(result.data),accountKey:result.accountKey)
    }
    func readResetCreditsWithContext(identitySalt: Data) async throws -> ResetCreditsReadSnapshot {
        let result=try await request(path:"/backend-api/wham/rate-limit-reset-credits",identitySalt:identitySalt)
        return ResetCreditsReadSnapshot(response:try ResetCreditDetails.decode(result.data),accountKey:result.accountKey)
    }
    // Reuse normal authorization. Pet models and caches receive only an opaque in-memory identity.
    func petAccountKey(identitySalt:Data) -> String? {
        guard identitySalt.count == 32,let data=credentialProvider(),
              let auth=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let tokens=auth["tokens"] as? [String:Any],
              let token=tokens["access_token"] as? String,!token.isEmpty,
              let id=tokens["account_id"] as? String,!id.isEmpty,id.utf8.count <= 512 else { return nil }
        return HMAC<SHA256>.authenticationCode(for:Data(id.utf8)+Data([0])+Data(token.utf8),using:SymmetricKey(data:identitySalt)).map { String(format:"%02x",$0) }.joined()
    }
    func readPetPage(cursor:String?,identitySalt:Data) async throws -> (data:Data,accountKey:String?) {
        var parts=URLComponents();parts.path="/backend-api/pets";parts.queryItems=[URLQueryItem(name:"limit",value:"20")]
        if let cursor {
            guard !cursor.isEmpty,cursor.utf8.count <= 2048,!cursor.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw UsageFailure.malformed }
            parts.queryItems?.append(URLQueryItem(name:"cursor",value:cursor))
        }
        guard let path=parts.string else { throw UsageFailure.malformed }
        let result=try await request(path:path,identitySalt:identitySalt,maximumBytes:1_000_000,petIdentity:true)
        guard result.accountKey != nil else { throw UsageFailure.authentication };return result
    }
    private func request(path: String, identitySalt: Data? = nil, maximumBytes:Int? = nil,petIdentity:Bool = false) async throws -> (data: Data, accountKey: String?) {
        guard let data = credentialProvider(),
              let auth = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let tokens = auth["tokens"] as? [String:Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { throw UsageFailure.authentication }
        var request = URLRequest(url:URL(string:"https://chatgpt.com\(path)")!)
        request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
        request.setValue("codex-cli",forHTTPHeaderField:"User-Agent")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        var accountKey: String?
        if let id = tokens["account_id"] as? String {
            request.setValue(id,forHTTPHeaderField:"ChatGPT-Account-Id")
            if let identitySalt, identitySalt.count == 32, !id.isEmpty, id.utf8.count <= 512 {
                let identity=petIdentity ? Data(id.utf8)+Data([0])+Data(token.utf8) : Data(id.utf8)
                let digest = HMAC<SHA256>.authenticationCode(for:identity,using:SymmetricKey(data:identitySalt))
                accountKey = digest.map { String(format:"%02x",$0) }.joined()
            }
        }
        do {
            let body:Data,response:URLResponse
            if let maximumBytes {
                let (stream,reply)=try await session.bytes(for:request);response=reply
                guard let http=reply as? HTTPURLResponse else { throw UsageFailure.unavailable }
                if http.statusCode == 401 || http.statusCode == 403 { throw UsageFailure.authentication }
                guard http.statusCode == 200 else { throw UsageFailure.unavailable }
                guard reply.expectedContentLength <= Int64(maximumBytes) else { throw UsageFailure.malformed }
                let consuming=Task.detached(priority:.utility) {
                    var data=Data()
                    for try await byte in stream {
                        try Task.checkCancellation();guard data.count < maximumBytes else { throw UsageFailure.malformed };data.append(byte)
                    };return data
                }
                body=try await withTaskCancellationHandler(operation:{try await consuming.value},onCancel:{consuming.cancel()})
                try Task.checkCancellation()
            } else { (body,response)=try await session.data(for:request) }
            guard let http = response as? HTTPURLResponse else { throw UsageFailure.unavailable }
            if http.statusCode == 401 || http.statusCode == 403 { throw UsageFailure.authentication }
            guard http.statusCode == 200 else { throw UsageFailure.unavailable }
            return (body,accountKey)
        } catch let error as UsageFailure { throw error }
          catch let error as URLError where error.code == .timedOut { throw UsageFailure.timeout }
          catch { throw UsageFailure.unavailable }
    }
    static func decode(_ data: Data) throws -> UsageResponse {
        guard let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              root["rate_limit"] != nil || root["plan_type"] != nil else { throw UsageFailure.malformed }
        func window(_ value: Any?) -> LimitWindow? {
            guard let w = value as? [String:Any], let used = w["used_percent"] as? Double, used.isFinite else { return nil }
            return LimitWindow(usedPercent:used,windowDurationMins:(w["limit_window_seconds"] as? Int).map { $0 / 60 },resetsAt:w["reset_at"] as? Double)
        }
        func bucket(_ value: Any?, id: String, name: String?) -> LimitBucket {
            let limits = value as? [String:Any] ?? [:]
            return LimitBucket(limitId:id,limitName:name,primary:window(limits["primary_window"]),secondary:window(limits["secondary_window"]),planType:root["plan_type"] as? String)
        }
        let primary = bucket(root["rate_limit"],id:"codex",name:nil)
        var map = ["codex":primary]
        for additional in root["additional_rate_limits"] as? [[String:Any]] ?? [] {
            guard let id = additional["metered_feature"] as? String else { continue }
            map[id] = bucket(additional["rate_limit"],id:id,name:additional["limit_name"] as? String)
        }
        let credits = (root["rate_limit_reset_credits"] as? [String:Any])?["available_count"] as? Int
        return UsageResponse(rateLimits:primary,rateLimitsByLimitId:map,rateLimitResetCredits:credits.map { ResetCredits(availableCount:$0) })
    }
    func stop() { session.invalidateAndCancel() }
}
