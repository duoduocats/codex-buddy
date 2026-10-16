import Foundation

final class QuotaFixture: URLProtocol {
    private struct Reply {
        let fixture: QuotaFixture
        let status: Int
        let failure: URLError?
        let body: Data
    }
    private static let lock = NSLock()
    private static var statusValue = 200
    private static var failureValue: URLError?
    private static var bodyValue = Data(#"{"plan_type":"test","rate_limit":null}"#.utf8)
    private static var requestCount = 0
    private static var bodies = [String:Data]()
    private static var paused = Set<String>()
    private static var pending = [String:[Reply]]()
    private static var waiters = [String:CheckedContinuation<URLRequest,Error>]()
    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock();defer { lock.unlock() };return body()
    }
    static var status: Int {
        get { locked { statusValue } }
        set { locked { statusValue = newValue } }
    }
    static var failure: URLError? {
        get { locked { failureValue } }
        set { locked { failureValue = newValue } }
    }
    static var body: Data {
        get { locked { bodyValue } }
        set { locked { bodyValue = newValue } }
    }
    static var requests: Int { locked { requestCount } }
    static var pathBodies: [String:Data] {
        get { locked { bodies } }
        set { locked { bodies = newValue } }
    }
    static func pause(_ path: String) { locked { _ = paused.insert(path) } }
    static func waitForSuspension(_ path: String) async throws -> URLRequest {
        let timeout = Task {
            do { try await Task.sleep(nanoseconds:5_000_000_000) } catch { return }
            let waiter = locked { waiters.removeValue(forKey:path) }
            waiter?.resume(throwing:NSError(domain:"SyntheticQuotaFixture",code:1))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let existing = locked { () -> URLRequest? in
                if let request = pending[path]?.first?.fixture.request { return request }
                waiters[path] = continuation;return nil
            }
            if let existing { continuation.resume(returning:existing) }
        }
    }
    static func resume(_ path: String) {
        let replies = locked { () -> [Reply] in
            paused.remove(path);return pending.removeValue(forKey:path) ?? []
        }
        for reply in replies { reply.fixture.send(reply) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "chatgpt.com")
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-test-only")
        let path = request.url!.path
        let result = Self.locked { () -> (Reply,Bool,CheckedContinuation<URLRequest,Error>?) in
            Self.requestCount += 1
            let reply = Reply(fixture:self,status:Self.statusValue,failure:Self.failureValue,body:Self.bodies[path] ?? Self.bodyValue)
            if Self.paused.contains(path) {
                Self.pending[path,default:[]].append(reply)
                return (reply,true,Self.waiters.removeValue(forKey:path))
            }
            return (reply,false,nil)
        }
        if result.1 { result.2?.resume(returning:request);return }
        send(result.0)
    }
    private func send(_ reply: Reply) {
        if let error = reply.failure { client?.urlProtocol(self,didFailWithError:error);return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:reply.status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.locked {
            for key in Array(Self.pending.keys) { Self.pending[key]?.removeAll { $0.fixture === self } }
        }
    }
}
@main struct NetworkTests {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaFixture.self]
        var anonymousCredentialReads = 0
        let client = UsageClient(configuration:configuration,credentialProvider: {
            anonymousCredentialReads += 1
            return Data(#"{"tokens":{"access_token":"synthetic-test-only"}}"#.utf8)
        })
        defer { client.stop() }
        _ = try await client.read()
        let salt = Data(repeating:7,count:32)
        let anonymous = try await client.readForForecast(identitySalt:salt)
        precondition(anonymous.accountKey == nil,"No account identity must not invent a persistent partition")
        var partition = "synthetic-partition-a", credentialReads = 0
        let identified = UsageClient(configuration:configuration,credentialProvider:{
            credentialReads += 1
            return try! JSONSerialization.data(withJSONObject:["tokens":["access_token":"synthetic-test-only","account_id":partition]])
        })
        let first = try await identified.readForForecast(identitySalt:salt)
        let same = try await identified.readForForecast(identitySalt:salt)
        precondition(first.accountKey?.count == 64 && first.accountKey == same.accountKey)
        precondition(first.accountKey != partition && credentialReads == 2,"One request reads its credentials once, with no extra identity lookup")
        partition = "synthetic-partition-b"
        let switched = try await identified.readForForecast(identitySalt:salt)
        precondition(switched.accountKey != first.accountKey && switched.response == first.response,"Identical quota responses must still separate accounts")
        let resalting = try await identified.readForForecast(identitySalt:Data(repeating:8,count:32))
        precondition(resalting.accountKey != switched.accountKey,"Local salt isolates independent histories")
        let invalidSalt = try await identified.readForForecast(identitySalt:Data())
        precondition(invalidSalt.accountKey == nil)
        QuotaFixture.pathBodies = [
            "/backend-api/wham/usage": Data(#"{"plan_type":"test","rate_limit":null}"#.utf8),
            "/backend-api/wham/profiles/me": Data(#"{"stats":{"lifetime_tokens":1250000,"daily_usage_buckets":[{"start_date":"2026-09-30","tokens":400000}]}}"#.utf8),
            "/backend-api/wham/rate-limit-reset-credits": Data(#"{"available_count":1,"credits":[{"id":"fixture-reset","reset_type":"codex_rate_limits","status":"available","expires_at":"2030-10-03T00:00:00Z"}]}"#.utf8)
        ]
        partition = "synthetic-partition-a"
        let readsBeforeContext = credentialReads
        let requestsBeforeContext = QuotaFixture.requests
        let quotaContext = try await identified.readForForecast(identitySalt:salt)
        let statisticsContext = try await identified.readStatisticsWithContext(identitySalt:salt)
        let resetContext = try await identified.readResetCreditsWithContext(identitySalt:salt)
        precondition(quotaContext.accountKey == first.accountKey && statisticsContext.accountKey == first.accountKey && resetContext.accountKey == first.accountKey,
                     "Quota, profile and reset responses must share one partition for the same captured account")
        precondition(statisticsContext.response.lifetimeTokens == 1250000 && resetContext.response.availableCount == 1)
        precondition(credentialReads == readsBeforeContext + 3 && QuotaFixture.requests == requestsBeforeContext + 3,
                     "Each contextual API uses exactly one existing request and one credential-provider read")
        try await capturedPartition(path:"/backend-api/wham/usage",expected:first.accountKey,switched:switched.accountKey,
            read:{ try await identified.readForForecast(identitySalt:salt).accountKey },
            setPartition:{ partition=$0 },credentialReads:{ credentialReads })
        try await capturedPartition(path:"/backend-api/wham/profiles/me",expected:first.accountKey,switched:switched.accountKey,
            read:{ try await identified.readStatisticsWithContext(identitySalt:salt).accountKey },
            setPartition:{ partition=$0 },credentialReads:{ credentialReads })
        try await capturedPartition(path:"/backend-api/wham/rate-limit-reset-credits",expected:first.accountKey,switched:switched.accountKey,
            read:{ try await identified.readResetCreditsWithContext(identitySalt:salt).accountKey },
            setPartition:{ partition=$0 },credentialReads:{ credentialReads })
        let anonymousBefore = anonymousCredentialReads
        let anonymousQuota = try await client.readForForecast(identitySalt:salt)
        let anonymousStatistics = try await client.readStatisticsWithContext(identitySalt:salt)
        let anonymousCredits = try await client.readResetCreditsWithContext(identitySalt:salt)
        precondition(anonymousQuota.accountKey == nil && anonymousStatistics.accountKey == nil && anonymousCredits.accountKey == nil)
        precondition(anonymousCredentialReads == anonymousBefore + 3,"Anonymous context must not perform an extra credential lookup")
        for badSalt in [Data(),Data(repeating:7,count:31),Data(repeating:7,count:33)] {
            let count = credentialReads
            let quota = try await identified.readForForecast(identitySalt:badSalt)
            let statistics = try await identified.readStatisticsWithContext(identitySalt:badSalt)
            let credits = try await identified.readResetCreditsWithContext(identitySalt:badSalt)
            precondition(quota.accountKey == nil && statistics.accountKey == nil && credits.accountKey == nil,
                         "Invalid salt never invents a persistent partition")
            precondition(credentialReads == count + 3)
        }
        QuotaFixture.pathBodies = [:]
        identified.stop()
        QuotaFixture.body = Data(#"{"stats":{"lifetime_tokens":1250000,"daily_usage_buckets":[{"start_date":"2026-09-30","tokens":400000}]}}"#.utf8)
        let statistics = try await client.readStatistics()
        precondition(statistics.lifetimeTokens == 1250000 && statistics.daily?.first?.tokens == 400000)
        QuotaFixture.body = Data(#"{"available_count":1,"credits":[{"id":"fixture-reset","reset_type":"codex_rate_limits","status":"available","expires_at":"2030-10-03T00:00:00Z"}]}"#.utf8)
        let details = try await client.readResetCredits()
        precondition(details.availableCount == 1 && details.credits.first?.expiresAt != nil)
        let contextualReads: [() async throws -> Void] = [
            { _ = try await client.readForForecast(identitySalt:salt) },
            { _ = try await client.readStatisticsWithContext(identitySalt:salt) },
            { _ = try await client.readResetCreditsWithContext(identitySalt:salt) }
        ]
        for status in [401,403,429,500] {
            QuotaFixture.status = status
            do { _ = try await client.readResetCredits();fatalError("Reset detail HTTP failure accepted") }
            catch UsageFailure.authentication { precondition(status == 401 || status == 403) }
            catch UsageFailure.unavailable { precondition(status == 429 || status == 500) }
            do { _ = try await client.read();fatalError("HTTP failure accepted") }
            catch UsageFailure.authentication { precondition(status == 401 || status == 403) }
            catch UsageFailure.unavailable { precondition(status == 429 || status == 500) }
            do { _ = try await client.readStatistics();fatalError("Statistics HTTP failure accepted") }
            catch UsageFailure.authentication { precondition(status == 401 || status == 403) }
            catch UsageFailure.unavailable { precondition(status == 429 || status == 500) }
            for read in contextualReads {
                do { try await read();fatalError("Contextual HTTP failure accepted") }
                catch UsageFailure.authentication { precondition(status == 401 || status == 403) }
                catch UsageFailure.unavailable { precondition(status == 429 || status == 500) }
            }
        }
        QuotaFixture.status = 200
        QuotaFixture.failure = URLError(.timedOut)
        do { _ = try await client.readResetCredits();fatalError("Reset detail timeout accepted") }
        catch UsageFailure.timeout {}
        do { _ = try await client.read();fatalError("Timeout accepted") }
        catch UsageFailure.timeout {}
        do { _ = try await client.readStatistics();fatalError("Statistics timeout accepted") }
        catch UsageFailure.timeout {}
        for read in contextualReads {
            do { try await read();fatalError("Contextual timeout accepted") }
            catch UsageFailure.timeout {}
        }
        QuotaFixture.failure = URLError(.notConnectedToInternet)
        do { _ = try await client.readResetCredits();fatalError("Reset detail offline accepted") }
        catch UsageFailure.unavailable {}
        do { _ = try await client.read();fatalError("Offline accepted") }
        catch UsageFailure.unavailable {}
        do { _ = try await client.readStatistics();fatalError("Statistics offline accepted") }
        catch UsageFailure.unavailable {}
        for read in contextualReads {
            do { try await read();fatalError("Contextual offline accepted") }
            catch UsageFailure.unavailable {}
        }
        QuotaFixture.failure = nil;QuotaFixture.body = Data("invalid-json".utf8)
        do { _ = try await client.readResetCredits();fatalError("Malformed reset details accepted") }
        catch UsageFailure.malformed {}
        do { _ = try await client.read();fatalError("Malformed body accepted") }
        catch UsageFailure.malformed {}
        do { _ = try await client.readStatistics();fatalError("Malformed statistics accepted") }
        catch UsageFailure.malformed {}
        for read in contextualReads {
            do { try await read();fatalError("Malformed contextual response accepted") }
            catch UsageFailure.malformed {}
        }
        let requests = QuotaFixture.requests
        let missing = UsageClient(configuration:configuration,credentialProvider:{ nil })
        do { _ = try await missing.read();fatalError("Missing credentials accepted") }
        catch UsageFailure.authentication {}
        for read in [
            { _ = try await missing.readForForecast(identitySalt:salt) },
            { _ = try await missing.readStatisticsWithContext(identitySalt:salt) },
            { _ = try await missing.readResetCreditsWithContext(identitySalt:salt) }
        ] {
            do { try await read();fatalError("Missing contextual credentials accepted") }
            catch UsageFailure.authentication {}
        }
        precondition(QuotaFixture.requests == requests)
        missing.stop()
        print("Synthetic network tests passed: legacy/context success and failures, single credential read, shared salted partition, queued account switch, anonymous/invalid salt, timeout/offline/malformed/missing credentials")
    }

    @MainActor static func capturedPartition(path: String,expected: String?,switched: String?,
        read: @escaping @MainActor () async throws -> String?,setPartition: (String) -> Void,
        credentialReads: () -> Int) async throws {
        setPartition("synthetic-partition-a")
        let before = credentialReads(), requestCount = QuotaFixture.requests
        QuotaFixture.pause(path)
        let operation = Task { try await read() }
        let request: URLRequest
        do { request = try await QuotaFixture.waitForSuspension(path) }
        catch { operation.cancel();QuotaFixture.resume(path);throw error }
        precondition(request.value(forHTTPHeaderField:"ChatGPT-Account-Id") == "synthetic-partition-a")
        precondition(credentialReads() == before + 1 && QuotaFixture.requests == requestCount + 1)
        setPartition("synthetic-partition-b")
        QuotaFixture.resume(path)
        let captured = try await operation.value
        precondition(captured == expected && captured != switched,
                     "A queued response must retain the partition captured when its request began")
        precondition(credentialReads() == before + 1,"Response completion must not re-read changed credentials")
        let next = try await read()
        precondition(next == switched && credentialReads() == before + 2,
                     "Only the next request adopts the new partition")
    }
}
