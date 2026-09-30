import Foundation
import AppKit

// No preference files or real credentials are read or written by these tests.
final class MemoryPreferences: UserDefaults {
    private var values = [String:Any]()
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?,forKey key: String) { values[key] = value }
}
final class ModelFixture: URLProtocol {
    static var statisticsRequests = 0
    static var quotaRequests = 0
    static var statisticsStatus = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-model-only")
        let isStatistics = request.url!.path == "/backend-api/wham/profiles/me"
        if isStatistics { Self.statisticsRequests += 1 } else {
            precondition(request.url!.path == "/backend-api/wham/usage");Self.quotaRequests += 1
        }
        let body = isStatistics
            ? #"{"stats":{"lifetime_tokens":1000,"daily_usage_buckets":[]}}"#
            : #"{"plan_type":"test","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1900000000}}}"#
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:isStatistics ? Self.statisticsStatus : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct ModelTests {
    @MainActor static func main() async throws {
        let preferences = MemoryPreferences()
        let configuration = URLSessionConfiguration.ephemeral;configuration.protocolClasses = [ModelFixture.self]
        let client = UsageClient(configuration:configuration,credentialProvider: { Data(#"{"tokens":{"access_token":"synthetic-model-only"}}"#.utf8) })
        defer { client.stop() }
        let model = AppModel(preferences:preferences,client:client)
        precondition(model.showUsageShareButton,"Sharing must be visible by default")
        model.showUsageShareButton = false
        precondition(!AppModel(preferences:preferences,client:client).showUsageShareButton,"Sharing visibility must persist")
        model.showUsageShareButton = true
        precondition(model.menuBarTheme == .ring,"Fresh preferences must preserve the ring theme")
        model.menuBarTheme = .duoDuoCat
        precondition(AppModel(preferences:preferences,client:client).menuBarTheme == .duoDuoCat,"Theme must survive model recreation")
        preferences.set("unknown-theme",forKey:"menuBarTheme")
        precondition(AppModel(preferences:preferences,client:client).menuBarTheme == .ring,"Unknown stored theme must fall back safely")
        model.menuBarTheme = .ring
        precondition(!model.menuShowsPercentage,"Fresh preferences must display time")
        model.menuShowsPercentage = true
        precondition(AppModel(preferences:preferences,client:client).menuShowsPercentage,"Menu mode must survive model recreation")
        model.menuShowsPercentage = false
        precondition(!preferences.bool(forKey:"menuShowsPercentage"))
        precondition(model.showDailyTokenUsage,"Fresh preferences must show the lower usage section")
        model.showDailyTokenUsage = false
        precondition(!AppModel(preferences:preferences,client:client).showDailyTokenUsage,"Usage visibility must survive model recreation")
        model.setPanelVisible(true);model.refresh();await wait(model)
        precondition(ModelFixture.statisticsRequests == 0,"Disabled usage must not query stats, including manual refresh")
        model.setPanelVisible(false)
        model.showDailyTokenUsage = true
        model.refresh(includeStatistics:false)
        await wait(model)
        precondition(ModelFixture.statisticsRequests == 0,"Closed panel must not query statistics")
        model.setPanelVisible(true);model.setPanelVisible(true)
        await wait(model)
        precondition(ModelFixture.statisticsRequests == 1 && model.statistics?.lifetimeTokens == 1000)
        model.setPanelVisible(false);model.setPanelVisible(true)
        await wait(model)
        precondition(ModelFixture.statisticsRequests == 1,"Reopening within the cache window must not request again")
        model.refresh();model.refresh()
        await wait(model)
        precondition(ModelFixture.statisticsRequests == 2,"Manual statistics refresh must be single-flight")
        ModelFixture.statisticsStatus = 503
        model.refresh();await wait(model)
        precondition(model.statistics?.lifetimeTokens == 1000 && model.statisticsError != nil,"Statistics failure must retain last successful result")
        precondition(model.window?.remaining == 90 && model.error == nil,"Statistics failure must not break quota")
        model.setPanelVisible(false)
        let count = ModelFixture.statisticsRequests
        model.refresh();await wait(model)
        precondition(ModelFixture.statisticsRequests == count,"Manual quota refresh with panel closed must not fetch stats")
        ModelFixture.statisticsStatus = 200
        model.showDailyTokenUsage = false;model.setPanelVisible(true);model.refresh();await wait(model)
        precondition(ModelFixture.statisticsRequests == count,"Disabled usage must keep cached stats without querying")
        precondition(model.window?.remaining == 90 && model.statistics?.lifetimeTokens == 1000,"Hiding stats must preserve quota and cached values")
        preferences.set(true,forKey:"showDailyTokenUsage")
        let reenabled = AppModel(preferences:preferences,client:client)
        reenabled.setPanelVisible(true);await wait(reenabled)
        precondition(ModelFixture.statisticsRequests == count+1,"Re-enabling usage must allow queries again")
        let updatedCount = ModelFixture.statisticsRequests
        let demo = AppModel(preferences:MemoryPreferences(),client:client)
        demo.useDemo();demo.setPanelVisible(true);demo.refresh()
        precondition(ModelFixture.statisticsRequests == updatedCount,"Demo screenshots must never query real services")
        print("Model integration passed: persisted themes and display switches, disabled statistics requests, panel-only requests, cache, single-flight, independent failures, demo privacy")
    }
    @MainActor static func wait(_ model: AppModel) async {
        for _ in 0..<200 {
            if !model.refreshing && !model.statisticsRefreshing { return }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        precondition(!model.refreshing && !model.statisticsRefreshing,"Model requests must finish")
    }
}
