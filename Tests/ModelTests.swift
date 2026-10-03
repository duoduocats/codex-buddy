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
    static var resetRequests = 0
    static var resetStatus = 200
    static var statisticsStatus = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-model-only")
        let isStatistics = request.url!.path == "/backend-api/wham/profiles/me"
        let isReset = request.url!.path == "/backend-api/wham/rate-limit-reset-credits"
        if isReset { Self.resetRequests += 1 }
        else if isStatistics { Self.statisticsRequests += 1 } else {
            precondition(request.url!.path == "/backend-api/wham/usage");Self.quotaRequests += 1
        }
        let body = isReset
            ? #"{"available_count":1,"credits":[{"id":"synthetic-reset","reset_type":"codex_rate_limits","status":"available","expires_at":"2030-10-03T00:00:00Z"}]}"#
            : isStatistics
            ? #"{"stats":{"lifetime_tokens":1000,"daily_usage_buckets":[]}}"#
            : #"{"plan_type":"test","rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1900000000}}}"#
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:isReset ? Self.resetStatus : isStatistics ? Self.statisticsStatus : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
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
        let environmentNotifications = NotificationCenter()
        let model = AppModel(preferences:preferences,client:client,environmentNotifications:environmentNotifications)
        for name in [Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            model.now = .distantPast
            environmentNotifications.post(name:name,object:nil)
            for _ in 0..<20 where model.now == .distantPast { try await Task.sleep(nanoseconds:1_000_000) }
            precondition(model.now != .distantPast,"System time zone and regional changes must immediately refresh visible dates")
        }
        precondition(ModelFixture.quotaRequests == 0 && ModelFixture.statisticsRequests == 0,"Time-zone refresh must not query usage")
        precondition(model.showUsageShareButton,"Sharing must be visible by default")
        model.showUsageShareButton = false
        precondition(!AppModel(preferences:preferences,client:client).showUsageShareButton,"Sharing visibility must persist")
        model.showUsageShareButton = true
        precondition(model.menuBarTheme == .duoDuoCat,"Fresh preferences must default to DuoDuoCat")
        model.menuBarTheme = .duoDuoCat
        precondition(AppModel(preferences:preferences,client:client).menuBarTheme == .duoDuoCat,"Theme must survive model recreation")
        preferences.set("unknown-theme",forKey:"menuBarTheme")
        precondition(AppModel(preferences:preferences,client:client).menuBarTheme == .duoDuoCat,"Unknown stored theme must fall back to the default")
        model.menuBarTheme = .ring
        precondition(AppModel(preferences:preferences,client:client).menuBarTheme == .ring,"Existing Ring choice must survive the new default")
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
        precondition(ModelFixture.resetRequests == 0 && !model.showResetDetails,"Existing UI must not query optional reset details")
        model.showResetDetails = true;await wait(model)
        precondition(ModelFixture.resetRequests == 1 && model.resetCreditDetails?.credits.count == 1)
        model.resetDetailsOnlySoonest = true
        let persisted = AppModel(preferences:preferences,client:client)
        precondition(persisted.showResetDetails && persisted.resetDetailsOnlySoonest,"Reset detail choices must survive restart")
        model.setPanelVisible(false);model.refresh();await wait(model)
        precondition(ModelFixture.resetRequests == 1,"Closed panel must not fetch reset details")
        model.setPanelVisible(true);await wait(model)
        precondition(ModelFixture.resetRequests == 1,"Reopening must reuse recent reset detail data")
        model.resetDetailsOnlySoonest = false
        precondition(ModelFixture.resetRequests == 1,"Changing display range must not request more data")
        ModelFixture.resetStatus = 503
        model.refresh();await wait(model)
        precondition(model.resetCreditDetails?.credits.count == 1 && model.resetCreditsError != nil && model.error == nil,
                     "Detail failure must retain expiry data and leave quota intact")
        let resetCount = ModelFixture.resetRequests
        model.showResetDetails = false;model.refresh();await wait(model)
        precondition(ModelFixture.resetRequests == resetCount,"Disabled details must not query the service")
        ModelFixture.resetStatus = 200
        model.showResetDetails = true;model.useDemo();model.refresh();await wait(model)
        precondition(ModelFixture.resetRequests <= resetCount+1 && model.resetCreditDetails?.credits.count == 2,
                     "Switching to demo must cancel any real detail request and retain synthetic data")
        print("Reset detail integration passed: opt-in and panel-only requests, persistence, cache, no-request filtering, failures and demo cancellation")
        print("Model integration passed: persisted themes and display switches, disabled statistics requests, panel-only requests, cache, single-flight, independent failures, demo privacy")
    }
    @MainActor static func wait(_ model: AppModel) async {
        for _ in 0..<200 {
            if !model.refreshing && !model.statisticsRefreshing && !model.resetCreditsRefreshing { return }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        precondition(!model.refreshing && !model.statisticsRefreshing && !model.resetCreditsRefreshing,"Model requests must finish")
    }
}
