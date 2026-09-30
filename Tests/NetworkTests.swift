import Foundation

final class QuotaFixture: URLProtocol {
    static var status = 200
    static var failure: URLError?
    static var body = Data(#"{"plan_type":"test","rate_limit":null}"#.utf8)
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        precondition(request.url?.host == "chatgpt.com")
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-test-only")
        if let error = Self.failure { client?.urlProtocol(self,didFailWithError:error);return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct NetworkTests {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaFixture.self]
        let client = UsageClient(configuration:configuration,credentialProvider: {
            Data(#"{"tokens":{"access_token":"synthetic-test-only"}}"#.utf8)
        })
        defer { client.stop() }
        _ = try await client.read()
        QuotaFixture.body = Data(#"{"stats":{"lifetime_tokens":1250000,"daily_usage_buckets":[{"start_date":"2026-09-30","tokens":400000}]}}"#.utf8)
        let statistics = try await client.readStatistics()
        precondition(statistics.lifetimeTokens == 1250000 && statistics.daily?.first?.tokens == 400000)
        for status in [401,403,429,500] {
            QuotaFixture.status = status
            do { _ = try await client.read();fatalError("HTTP failure accepted") }
            catch UsageFailure.authentication { precondition(status == 401 || status == 403) }
            catch UsageFailure.unavailable { precondition(status == 429 || status == 500) }
            do { _ = try await client.readStatistics();fatalError("Statistics HTTP failure accepted") }
            catch UsageFailure.authentication { precondition(status == 401 || status == 403) }
            catch UsageFailure.unavailable { precondition(status == 429 || status == 500) }
        }
        QuotaFixture.status = 200
        QuotaFixture.failure = URLError(.timedOut)
        do { _ = try await client.read();fatalError("Timeout accepted") }
        catch UsageFailure.timeout {}
        do { _ = try await client.readStatistics();fatalError("Statistics timeout accepted") }
        catch UsageFailure.timeout {}
        QuotaFixture.failure = URLError(.notConnectedToInternet)
        do { _ = try await client.read();fatalError("Offline accepted") }
        catch UsageFailure.unavailable {}
        do { _ = try await client.readStatistics();fatalError("Statistics offline accepted") }
        catch UsageFailure.unavailable {}
        QuotaFixture.failure = nil;QuotaFixture.body = Data("invalid-json".utf8)
        do { _ = try await client.read();fatalError("Malformed body accepted") }
        catch UsageFailure.malformed {}
        do { _ = try await client.readStatistics();fatalError("Malformed statistics accepted") }
        catch UsageFailure.malformed {}
        let requests = QuotaFixture.requests
        let missing = UsageClient(configuration:configuration,credentialProvider:{ nil })
        do { _ = try await missing.read();fatalError("Missing credentials accepted") }
        catch UsageFailure.authentication {}
        precondition(QuotaFixture.requests == requests)
        missing.stop()
        print("Synthetic network tests passed: success, auth failure, throttling, server error, timeout, offline, malformed response, missing credentials")
    }
}
