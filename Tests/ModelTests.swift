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
// Account markers, credentials and payloads below are entirely synthetic.
final class AccountModelFixture: URLProtocol {
    static let a="synthetic-account-a",b="synthetic-account-b"
    private static let lock=NSLock()
    private static var held=Set<String>()
    private static var queued=[String:[AccountModelFixture]]()
    private static var counts=[String:Int]()
    private var finished=false
    private var account="anonymous"
    private var kind="quota"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func key(_ account: String,_ kind: String) -> String { account+"|"+kind }
    static func hold(_ account: String,_ kind: String) { lock.lock();held.insert(key(account,kind));lock.unlock() }
    static func count(_ account: String,_ kind: String) -> Int { lock.lock();defer { lock.unlock() };return counts[key(account,kind)] ?? 0 }
    static func pending(_ account: String,_ kind: String) -> Int { lock.lock();defer { lock.unlock() };return queued[key(account,kind)]?.count ?? 0 }
    static func release(_ account: String,_ kind: String) {
        lock.lock();let value=key(account,kind);held.remove(value);let pending=queued.removeValue(forKey:value) ?? [];lock.unlock()
        pending.forEach { $0.finish() }
    }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-account-isolation")
        account=request.value(forHTTPHeaderField:"ChatGPT-Account-Id") ?? "anonymous"
        if request.url?.path == "/backend-api/wham/profiles/me" { kind="profile" }
        else if request.url?.path == "/backend-api/wham/rate-limit-reset-credits" { kind="reset" }
        else { precondition(request.url?.path == "/backend-api/wham/usage") }
        let value=Self.key(account,kind)
        Self.lock.lock();Self.counts[value,default:0] += 1
        if Self.held.contains(value) { Self.queued[value,default:[]].append(self);Self.lock.unlock();return }
        Self.lock.unlock();finish()
    }
    override func stopLoading() { Self.lock.lock();finished=true;Self.lock.unlock() }
    private func finish() {
        Self.lock.lock();guard !finished else { Self.lock.unlock();return };finished=true;Self.lock.unlock()
        let isB=account == Self.b
        let body: String
        if kind == "profile" {
            let tokens=account == "anonymous" ? 333 : isB ? 222 : 111
            body="{\"stats\":{\"lifetime_tokens\":\(tokens),\"daily_usage_buckets\":[{\"start_date\":\"2026-10-10\",\"tokens\":\(tokens)}]}}"
        } else if kind == "reset" {
            let day=isB ? "04" : "03"
            body="{\"available_count\":1,\"credits\":[{\"id\":\"synthetic-expiry\",\"reset_type\":\"codex_rate_limits\",\"status\":\"available\",\"expires_at\":\"2030-10-\(day)T00:00:00Z\"}]}"
        } else {
            let percent=isB ? 70 : 10
            body="{\"plan_type\":\"synthetic\",\"rate_limit\":{\"primary_window\":{\"used_percent\":\(percent),\"limit_window_seconds\":604800,\"reset_at\":4000000000}},\"rate_limit_reset_credits\":{\"available_count\":1}}"
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
}

final class ForecastModelFixture: URLProtocol {
    private static let lock=NSLock()
    private static var used=70.0,reset=Date().addingTimeInterval(18 * 3_600)
    private static var status=200,held=false
    private static var pending=[ForecastModelFixture]()
    private static var requests=0
    private var body=Data(),responseStatus=200,finished=false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func configure(used: Double,reset: Date,status: Int = 200) {
        lock.lock();Self.used=used;Self.reset=reset;Self.status=status;lock.unlock()
    }
    static func suspendQuota() { lock.lock();held=true;lock.unlock() }
    static var pendingCount: Int { lock.lock();defer { lock.unlock() };return pending.count }
    static var requestCount: Int { lock.lock();defer { lock.unlock() };return requests }
    static func releaseQuota() {
        lock.lock();held=false;let work=pending;pending=[];lock.unlock();work.forEach { $0.finish() }
    }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-forecast-model")
        let profile=request.url?.path == "/backend-api/wham/profiles/me"
        if profile {
            let tokens=request.value(forHTTPHeaderField:"ChatGPT-Account-Id") == "synthetic-forecast-b" ? 222 : 111
            body=Data("{\"stats\":{\"lifetime_tokens\":\(tokens),\"daily_usage_buckets\":[]}}".utf8);finish();return
        }
        precondition(request.url?.path == "/backend-api/wham/usage")
        Self.lock.lock();Self.requests += 1
        body=Data("{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":\(Self.used),\"limit_window_seconds\":604800,\"reset_at\":\(Self.reset.timeIntervalSince1970)}}}".utf8)
        responseStatus=Self.status
        if Self.held { Self.pending.append(self);Self.lock.unlock();return }
        Self.lock.unlock();finish()
    }
    override func stopLoading() { Self.lock.lock();finished=true;Self.lock.unlock() }
    private func finish() {
        Self.lock.lock();guard !finished else { Self.lock.unlock();return };finished=true;Self.lock.unlock()
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:responseStatus,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
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
        precondition(model.challenge.enabled,"Activity reception defaults on")
        model.reminders.setActivityMessagesEnabled(false)
        precondition(!model.challenge.enabled && model.reminders.acceptsResetMessages,"Activity opt out is independent of resets")
        model.reminders.setActivityMessagesEnabled(true)
        model.reminders.setResetMessagesEnabled(false)
        precondition(model.challenge.enabled,"Disabling reset reminders keeps activity reception")
        model.reminders.setMessagesEnabled(false)
        precondition(!model.challenge.enabled,"The master still disables activity when reset reminders are off")
        model.reminders.setMessagesEnabled(true)
        precondition(model.challenge.enabled && !model.reminders.resetMessagesEnabled,"Master resumes saved category choices")
        model.reminders.setResetMessagesEnabled(true)
        precondition(model.resetExpiryWindowDays == 7,"New expiry windows default to seven days")
        model.resetExpiryWindowDays = 14
        precondition(AppModel(preferences:preferences,client:client).resetExpiryWindowDays == 14,"Expiry window choice persists")
        model.resetExpiryWindowDays = 7
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
        model.resetExpiryWindowDays = 14
        precondition(ModelFixture.resetRequests == 1,"Changing expiry days must not request more data")
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
        await testUsageTrendsVisibility(client:client,configuration:configuration)
        try await testAccountIsolation()
        try await testForecastEvaluationIntegration()
        print("Reset detail integration passed: opt-in and panel-only requests, persistence, cache, no-request filtering, failures and demo cancellation")
        print("Model integration passed: persisted themes and display switches, disabled statistics requests, panel-only requests, cache, single-flight, independent failures, demo privacy")
    }
    @MainActor static func testUsageTrendsVisibility(client: UsageClient,configuration: URLSessionConfiguration) async {
        let preferences = MemoryPreferences()
        preferences.set(false,forKey:"showDailyTokenUsage")
        let notifications = NotificationCenter()
        let trends = AppModel(preferences:preferences,client:client,environmentNotifications:notifications)
        let originalStatisticsRequests = ModelFixture.statisticsRequests
        let originalQuotaRequests = ModelFixture.quotaRequests
        let originalResetRequests = ModelFixture.resetRequests
        precondition(!trends.isDemonstrating)
        trends.refreshUsageTrends();await wait(trends)
        precondition(ModelFixture.statisticsRequests == originalStatisticsRequests,"Inactive trends must not request statistics")

        trends.setMainWindowVisible(false);trends.setUsageTrendsVisible(true);trends.refreshUsageTrends()
        await wait(trends)
        precondition(ModelFixture.statisticsRequests == originalStatisticsRequests,"Trends selected in a closed or minimized window must not query statistics")
        trends.setMainWindowVisible(true)
        precondition(trends.statisticsRefreshing,"Entering visible trends must schedule an eligible statistics request even with the popover chart off")
        trends.setUsageTrendsVisible(true);trends.setUsageTrendsVisible(false);trends.setUsageTrendsVisible(true)
        trends.setMainWindowVisible(true);trends.refreshUsageTrends();trends.refreshUsageTrends()
        await wait(trends)
        precondition(ModelFixture.statisticsRequests == originalStatisticsRequests+1 && trends.statistics?.lifetimeTokens == 1000,
                     "Repeated entry and refresh while a statistics request is in flight must remain single-flight")
        precondition(ModelFixture.quotaRequests == originalQuotaRequests && ModelFixture.resetRequests == originalResetRequests,
                     "Trends entry and refresh must query only statistics")
        precondition(!trends.showDailyTokenUsage && !preferences.bool(forKey:"showDailyTokenUsage"),
                     "Opening trends must preserve the disabled popover chart preference")

        trends.setUsageTrendsVisible(false);trends.setUsageTrendsVisible(true);await wait(trends)
        precondition(ModelFixture.statisticsRequests == originalStatisticsRequests+1,"Reopening trends must reuse the existing five-minute cache")
        trends.refreshUsageTrends();trends.refreshUsageTrends();await wait(trends)
        precondition(ModelFixture.statisticsRequests == originalStatisticsRequests+2,"Manual trends refresh must force one statistics request")
        precondition(ModelFixture.quotaRequests == originalQuotaRequests && ModelFixture.resetRequests == originalResetRequests,
                     "Manual trends refresh must not fetch quota or optional reset details")
        let visibleStatisticsRequests = ModelFixture.statisticsRequests
        for name in [Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            trends.now = .distantPast;notifications.post(name:name,object:nil)
            for _ in 0..<20 where trends.now == .distantPast { try? await Task.sleep(nanoseconds:1_000_000) }
            precondition(trends.now != .distantPast,"Visible trends dates must update when the system environment changes")
        }
        trends.now = trends.now.addingTimeInterval(86400)
        precondition(ModelFixture.statisticsRequests == visibleStatisticsRequests,"Date and time-zone display updates must not query statistics")

        trends.setUsageTrendsVisible(false);trends.refreshUsageTrends();await wait(trends)
        precondition(ModelFixture.statisticsRequests == visibleStatisticsRequests,"Leaving trends must suppress later page refresh requests")
        trends.setMainWindowVisible(false);trends.setUsageTrendsVisible(true);trends.refreshUsageTrends();await wait(trends)
        precondition(ModelFixture.statisticsRequests == visibleStatisticsRequests,"Closing or minimizing the main window must suppress subsequent trends refresh requests")
        trends.setMainWindowVisible(true);await wait(trends)
        precondition(ModelFixture.statisticsRequests == visibleStatisticsRequests,"Restoring a window must still honor the statistics cache")
        trends.showDailyTokenUsage = true;trends.showDailyTokenUsage = false
        trends.refreshUsageTrends();await wait(trends)
        precondition(ModelFixture.statisticsRequests == visibleStatisticsRequests+1,
                     "Turning off the tiny popover chart must leave the visible trends page able to refresh")
        trends.setMainWindowVisible(false);trends.showDailyTokenUsage = true;trends.setPanelVisible(true)
        trends.refresh();await wait(trends)
        precondition(ModelFixture.statisticsRequests == visibleStatisticsRequests+2,
                     "A visible popover chart must continue to refresh independently of main-window visibility")
        trends.setPanelVisible(false)

        let beforeDemo = ModelFixture.statisticsRequests
        let demo = AppModel(preferences:MemoryPreferences(),client:client)
        demo.useDemo();precondition(demo.isDemonstrating)
        demo.setUsageTrendsVisible(true);demo.setMainWindowVisible(false);demo.setMainWindowVisible(true)
        demo.refreshUsageTrends();demo.setPanelVisible(true);demo.refresh();await wait(demo)
        precondition(ModelFixture.statisticsRequests == beforeDemo,"Demonstration trends must never query services")
        let queuedDemo = AppModel(preferences:MemoryPreferences(),client:client)
        queuedDemo.setUsageTrendsVisible(true);queuedDemo.useDemo();await wait(queuedDemo)
        precondition(ModelFixture.statisticsRequests == beforeDemo && queuedDemo.statistics == .demo(now:queuedDemo.now),
                     "Entering demonstration before a queued statistics task starts must retain synthetic data without querying")

        var absentCredentialReads = 0
        let unauthenticated = UsageClient(configuration:configuration,credentialProvider: {
            absentCredentialReads += 1;return nil
        })
        defer { unauthenticated.stop() }
        let noAuth = AppModel(preferences:MemoryPreferences(),client:unauthenticated)
        noAuth.setUsageTrendsVisible(true);noAuth.refreshUsageTrends();await wait(noAuth)
        precondition(absentCredentialReads == 1 && noAuth.statisticsError != nil && ModelFixture.statisticsRequests == beforeDemo,
                     "Absent synthetic authentication must fail without a request or fallback to an original credential provider")
        noAuth.setUsageTrendsVisible(false);noAuth.setUsageTrendsVisible(true);await wait(noAuth)
        precondition(absentCredentialReads == 1,"Failed trends entry must keep the existing statistics retry backoff")
        noAuth.refreshUsageTrends();await wait(noAuth)
        precondition(absentCredentialReads == 2 && ModelFixture.statisticsRequests == beforeDemo,
                     "Explicit retry must use only the injected absent-auth provider and must not send a request")
        var account = "synthetic-model-partition-a"
        let partitioned = UsageClient(configuration:configuration,credentialProvider:{
            try! JSONSerialization.data(withJSONObject:["tokens":["access_token":"synthetic-model-only","account_id":account]])
        })
        defer { partitioned.stop() }
        let forecastNotifications = NotificationCenter()
        let observed = AppModel(preferences:MemoryPreferences(),client:partitioned,environmentNotifications:forecastNotifications)
        let beforeQuota = ModelFixture.quotaRequests
        observed.refresh(includeStatistics:false);await wait(observed)
        let firstIdentity=observed.forecastIdentity
        precondition(firstIdentity?.count == 64 && observed.forecastObservations.count == 1)
        let firstQuota=observed.usage
        observed.refresh(includeStatistics:false);await wait(observed)
        precondition(observed.usage == firstQuota && observed.forecastObservations.count == 2,
                     "Each successful request, including unchanged quotas, must retain an observation")
        account = "synthetic-model-partition-b"
        observed.refresh(includeStatistics:false);await wait(observed)
        precondition(observed.forecastIdentity != firstIdentity && observed.forecastObservations.count == 1,
                     "Account changes must not inherit a previous account's burn rate")
        forecastNotifications.post(name:.buddyUsageForecastCacheCleared,object:nil)
        for _ in 0..<20 where !observed.forecastObservations.isEmpty { try? await Task.sleep(nanoseconds:1_000_000) }
        precondition(observed.forecastObservations.isEmpty && observed.usage == firstQuota,
                     "Clearing local forecast history must preserve the current real quota")
        precondition(ModelFixture.quotaRequests == beforeQuota+3,"History capture and clearing must not add polling")
        print("Usage trends model integration passed: independent chart preference, visibility, cache, single-flight, stats-only manual refresh, time-zone updates, demo privacy and absent synthetic authentication")
    }
    @MainActor static func testAccountIsolation() async throws {
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[AccountModelFixture.self]
        var account=AccountModelFixture.a
        let client=UsageClient(configuration:configuration,credentialProvider:{
            try! JSONSerialization.data(withJSONObject:["tokens":["access_token":"synthetic-account-isolation","account_id":account]])
        })
        defer { client.stop() }
        let preferences=MemoryPreferences();preferences.set(false,forKey:"showDailyTokenUsage");preferences.set(true,forKey:"showResetDetails")
        let notifications=NotificationCenter()
        let model=AppModel(preferences:preferences,client:client,environmentNotifications:notifications)
        model.refresh(includeStatistics:false);await wait(model)
        model.setUsageTrendsVisible(true);model.setPanelVisible(true);await wait(model)
        let expiryA=ISO8601DateFormatter().date(from:"2030-10-03T00:00:00Z")!
        let expiryB=ISO8601DateFormatter().date(from:"2030-10-04T00:00:00Z")!
        precondition(model.statistics?.lifetimeTokens == 111 && model.resetCreditDetails?.credits.first?.expiresAt == expiryA)
        let profileA=AccountModelFixture.count(AccountModelFixture.a,"profile")
        model.setUsageTrendsVisible(false);model.setUsageTrendsVisible(true);await wait(model)
        precondition(AccountModelFixture.count(AccountModelFixture.a,"profile") == profileA)
        account=AccountModelFixture.b
        model.refresh(includeStatistics:false);await wait(model)
        precondition(model.window?.usedPercent == 70 && model.statistics?.lifetimeTokens == 222,
                     "Known account changes invalidate the old five-minute profile cache immediately")
        precondition(model.resetCreditDetails?.credits.first?.expiresAt == expiryB,
                     "Equal available counts cannot retain another account's credit expirations")
        precondition(AccountModelFixture.count(AccountModelFixture.b,"profile") == 1 && AccountModelFixture.count(AccountModelFixture.b,"reset") == 1)

        // Keep an A profile response suspended while a B quota identifies the
        // switch. Its completion must release, then refill, the single-flight slot.
        account=AccountModelFixture.a;model.refresh(includeStatistics:false);await wait(model)
        AccountModelFixture.hold(account,"profile")
        model.refreshUsageTrends()
        try await awaitCondition { AccountModelFixture.pending(AccountModelFixture.a,"profile") == 1 }
        account=AccountModelFixture.b;model.refresh(includeStatistics:false)
        try await awaitCondition { !model.refreshing }
        precondition(model.statistics == nil && model.statisticsUpdated == nil,
                     "Detected switches clear private profile values before a delayed old response finishes")
        let pendingB=AccountModelFixture.count(AccountModelFixture.b,"profile")
        AccountModelFixture.release(AccountModelFixture.a,"profile");await wait(model)
        precondition(model.statistics?.lifetimeTokens == 222 && AccountModelFixture.count(AccountModelFixture.b,"profile") == pendingB+1,
                     "A late old profile cannot overwrite B; one visible refill runs after its defer")

        // The profile endpoint can identify B before a suspended A quota. The
        // old quota must not switch the identity back to A when it eventually arrives.
        account=AccountModelFixture.a;model.refresh(includeStatistics:false);await wait(model)
        AccountModelFixture.hold(account,"quota");model.refresh(includeStatistics:false)
        try await awaitCondition { AccountModelFixture.pending(AccountModelFixture.a,"quota") == 1 }
        account=AccountModelFixture.b;model.refreshUsageTrends()
        try await awaitCondition { !model.statisticsRefreshing && model.statistics?.lifetimeTokens == 222 }
        precondition(model.usage == nil && model.updated == nil,"Profile-first identity changes discard the old quota while its request remains in flight")
        let identityB=model.forecastIdentity
        AccountModelFixture.release(AccountModelFixture.a,"quota");await wait(model)
        precondition(model.forecastIdentity == identityB && model.window?.usedPercent == 70 && model.statistics?.lifetimeTokens == 222,
                     "An A quota returning after B's profile cannot revive A's quota or forecast identity")

        // A canceled old detail's defer must not unlock or replace B's detail.
        account=AccountModelFixture.a;model.refresh(includeStatistics:false);await wait(model)
        AccountModelFixture.hold(account,"reset");model.refresh()
        try await awaitCondition { AccountModelFixture.pending(AccountModelFixture.a,"reset") == 1 && !model.refreshing && !model.statisticsRefreshing }
        account=AccountModelFixture.b;model.refresh(includeStatistics:false);await wait(model)
        precondition(model.resetCreditDetails?.credits.first?.expiresAt == expiryB)
        AccountModelFixture.release(AccountModelFixture.a,"reset")
        try await Task.sleep(nanoseconds:20_000_000)
        precondition(!model.resetCreditsRefreshing && model.resetCreditDetails?.credits.first?.expiresAt == expiryB,
                     "Late canceled A details cannot replace B or corrupt its single-flight flag")

        // Hidden history is cleared on a switch, but privacy invalidation does
        // not introduce a hidden-window profile poll.
        model.setPanelVisible(false);model.setMainWindowVisible(false)
        account=AccountModelFixture.a
        let hiddenProfiles=AccountModelFixture.count(account,"profile")
        model.refresh(includeStatistics:false);await wait(model)
        precondition(model.statistics == nil && AccountModelFixture.count(account,"profile") == hiddenProfiles)
        model.setMainWindowVisible(true);await wait(model)
        precondition(model.statistics?.lifetimeTokens == 111 && AccountModelFixture.count(account,"profile") == hiddenProfiles+1)

        // Clearing forecast history invalidates the pending observation while
        // preserving the successful current quota itself.
        AccountModelFixture.hold(account,"quota");model.refresh(includeStatistics:false)
        try await awaitCondition { AccountModelFixture.pending(AccountModelFixture.a,"quota") == 1 }
        notifications.post(name:.buddyUsageForecastCacheCleared,object:nil)
        try await awaitCondition { model.forecastObservations.isEmpty }
        AccountModelFixture.release(AccountModelFixture.a,"quota");await wait(model)
        precondition(model.forecastObservations.isEmpty && model.window?.usedPercent == 10,
                     "Late pre-clear observations remain discarded without deleting the actual quota")

        let anonymous=UsageClient(configuration:configuration,credentialProvider:{
            Data(#"{"tokens":{"access_token":"synthetic-account-isolation"}}"#.utf8)
        })
        defer { anonymous.stop() }
        let unknown=AppModel(preferences:MemoryPreferences(),client:anonymous)
        let unknownQuotas=AccountModelFixture.count("anonymous","quota")
        unknown.setUsageTrendsVisible(true);await wait(unknown)
        precondition(unknown.forecastIdentity == nil && unknown.statistics?.lifetimeTokens == 333
                     && AccountModelFixture.count("anonymous","quota") == unknownQuotas,
                     "The first unknown partition does not manufacture a switch or force a quota lookup")
        var credentialReads=0
        let demoClient=UsageClient(configuration:configuration,credentialProvider:{ credentialReads += 1;return nil })
        defer { demoClient.stop() }
        let queuedDemo=AppModel(preferences:MemoryPreferences(),client:demoClient)
        queuedDemo.refresh(includeStatistics:false);queuedDemo.useDemo();await wait(queuedDemo)
        precondition(credentialReads == 0 && queuedDemo.isDemonstrating && queuedDemo.statistics?.lifetimeTokens == 4_860_000_000,
                     "Entering demonstration before a queued quota task starts never reads credentials")
        print("Account isolation passed: cached and delayed profiles, profile-first/quota-first switches, reset-detail cancellation, hidden refills, clear races, unknown identity and demo privacy")
    }
    @MainActor private static func awaitCondition(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        preconditionFailure("Synthetic account request did not reach the required state")
    }

    @MainActor static func testForecastEvaluationIntegration() async throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:"/private/tmp/buddy-model-forecast-tests-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let evaluationStore=UsageForecastEvaluationStore(directory:root)
        let notifications=NotificationCenter(),preferences=MemoryPreferences()
        preferences.set(false,forKey:"showDailyTokenUsage")
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[ForecastModelFixture.self]
        var account="synthetic-forecast-a"
        let client=UsageClient(configuration:configuration,credentialProvider:{
            Data("{\"tokens\":{\"access_token\":\"synthetic-forecast-model\",\"account_id\":\"\(account)\"}}".utf8)
        })
        defer { client.stop() }
        let model=AppModel(preferences:preferences,client:client,environmentNotifications:notifications,
            forecastEvaluationStore:evaluationStore)
        let reset=Date().addingTimeInterval(18 * 3_600)
        ForecastModelFixture.configure(used:70,reset:reset)
        model.refresh(includeStatistics:false);await wait(model)
        precondition(model.forecastIdentity != nil && model.forecastEvaluations.isEmpty
            && !FileManager.default.fileExists(atPath:root.appendingPathComponent("evaluation.json").path),
            "The first unknown account skips issuance without a new RPC or manufactured identity")
        func seed(used: Double,reset: Date) {
            let endpoint=model.updated!
            let actualReset=model.window!.resetDate!
            model.forecastObservations=(0...72).map { index in
                UsageForecastObservation(windowID:.init(bucketID:"codex",role:.primary),
                    observedAt:endpoint.addingTimeInterval(Double(index - 72) * 300),
                    usedPercent:used - 12 + Double(index) / 6,windowDurationMins:10_080,
                    resetDate:actualReset,planType:"plus",source:"native-wham")
            }
        }
        seed(used:70,reset:reset)
        let before=ForecastModelFixture.requestCount
        model.refresh(includeStatistics:false);await wait(model)
        precondition(ForecastModelFixture.requestCount == before + 1 && model.forecastEvaluations.count == 1,
                     "Ready successful quota reads issue a baseline without another request")
        let original=model.forecastEvaluations[0].prediction
        precondition(original.origin == .baseline && original.modelVersion == "recent-linear-v2"
            && original.inputCutoff <= original.issuedAt && original.segmentID != nil
            && original.rate.map { abs($0 - 2) < 0.001 } == true && original.remaining == 30)
        model.demoForecastExtraDate=Date().addingTimeInterval(9 * 3_600)
        precondition(model.demoForecastExtraDate == nil,"Real account data cannot enable a injected demonstration scenario")
        ForecastModelFixture.configure(used:72,reset:reset)
        model.refresh(includeStatistics:false);await wait(model)
        precondition(model.forecastEvaluations.count == 1 && model.forecastEvaluations[0].prediction == original,
                     "Later fits cannot refit an already-issued baseline or inflate same-cycle accuracy samples")
        ForecastModelFixture.configure(used:100,reset:reset)
        model.refresh(includeStatistics:false);await wait(model)
        guard case .scored(let score)=model.forecastEvaluations[0].evaluation else { preconditionFailure("Reported exhaustion was not scored") }
        precondition(score.observedUpper == model.updated && score.observedLower >= original.inputCutoff
            && score.minimumAbsoluteError > 0,"Accuracy comes from a real observed depletion interval, not retroactive agreement")
        let terminal=model.forecastEvaluations[0]
        let nextReset=reset.addingTimeInterval(7 * 86_400)
        ForecastModelFixture.configure(used:20,reset:nextReset)
        model.refresh(includeStatistics:false);await wait(model)
        precondition(model.forecastEvaluations == [terminal],"A later reset/drop cannot rewrite a terminal score")
        seed(used:20,reset:nextReset)
        model.refresh(includeStatistics:false);await wait(model)
        precondition(model.forecastEvaluations.count == 2 && model.forecastEvaluations.contains(terminal))

        // A current request captures its token BEFORE clearing. Its real quota
        // can publish later, but neither retained samples nor ledger can revive.
        ForecastModelFixture.suspendQuota();model.refresh(includeStatistics:false)
        try await awaitCondition { ForecastModelFixture.pendingCount == 1 }
        try await evaluationStore.clear()
        notifications.post(name:.buddyUsageForecastCacheCleared,object:nil)
        try await awaitCondition { model.forecastEvaluations.isEmpty && model.forecastObservations.isEmpty }
        ForecastModelFixture.releaseQuota();await wait(model)
        precondition(model.window?.usedPercent == 20 && model.forecastEvaluations.isEmpty && model.forecastObservations.isEmpty
            && !FileManager.default.fileExists(atPath:root.appendingPathComponent("evaluation.json").path))
        model.refresh(includeStatistics:false);await wait(model)
        seed(used:20,reset:nextReset);model.refresh(includeStatistics:false);await wait(model)
        precondition(model.forecastEvaluations.count == 1,"A genuine read after clear can establish a new immutable baseline")
        let aPrediction=model.forecastEvaluations[0].prediction

        ForecastModelFixture.suspendQuota();model.refresh(includeStatistics:false)
        try await awaitCondition { ForecastModelFixture.pendingCount == 1 }
        account="synthetic-forecast-b";model.setUsageTrendsVisible(true)
        try await awaitCondition { !model.statisticsRefreshing && model.statistics?.lifetimeTokens == 222 }
        let bIdentity=model.forecastIdentity
        precondition(model.forecastEvaluations.isEmpty && model.usage == nil)
        ForecastModelFixture.releaseQuota();await wait(model)
        precondition(model.forecastIdentity == bIdentity && model.forecastEvaluations.isEmpty,
                     "A held A response cannot revive A's ledger after a profile identifies B")
        seed(used:20,reset:nextReset);model.refresh(includeStatistics:false);await wait(model)
        precondition(model.forecastEvaluations.count == 1 && model.forecastEvaluations[0].prediction.id != aPrediction.id,
                     "Current account publishes only its independent ledger")
        let bRecord=model.forecastEvaluations[0]
        ForecastModelFixture.configure(used:20,reset:nextReset,status:503)
        model.refresh(includeStatistics:false);await wait(model)
        precondition(model.error != nil && model.forecastEvaluations == [bRecord],"Failed reads never issue or evaluate a new prediction")
        let requests=ForecastModelFixture.requestCount
        model.useDemo();model.demoForecastExtraDate=model.now.addingTimeInterval(9 * 3_600)
        model.refresh(includeStatistics:false);await wait(model)
        precondition(model.forecastEvaluations.isEmpty && model.forecastIdentity == nil
            && model.demoForecastExtraDate != nil && ForecastModelFixture.requestCount == requests)
        model.demoForecastExtraDate=Date(timeIntervalSince1970:.infinity)
        precondition(model.demoForecastExtraDate == nil)
        print("Forecast ledger model integration passed: existing-request issuance, immutable per-cycle inputs, real outcome intervals, no retroactive refit, clear/account races, independent accounts, errors and demo isolation")
    }

    @MainActor static func wait(_ model: AppModel) async {
        for _ in 0..<200 {
            if !model.refreshing && !model.statisticsRefreshing && !model.resetCreditsRefreshing { return }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        precondition(!model.refreshing && !model.statisticsRefreshing && !model.resetCreditsRefreshing,"Model requests must finish")
    }
}
