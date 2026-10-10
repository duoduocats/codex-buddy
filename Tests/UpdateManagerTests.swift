import AppKit
import CryptoKit

final class PolicyFixtureProtocol: URLProtocol {
    static var responses: [String: (Int,Data)] = [:]
    static var requests: [String] = []
    static var responseHeaders: [String:[String:String]] = [:]
    static var requestHeaders: [String:[String:String]] = [:]
    private static let gateLock = NSLock()
    private static var gatedURL: String?
    private static var suspended = [(PolicyFixtureProtocol,URL,(Int,Data))]()
    static func pause(_ url: String) {
        gateLock.lock();defer { gateLock.unlock() }
        precondition(gatedURL == nil && suspended.isEmpty,"A previous synthetic metadata request is still gated")
        gatedURL = url
    }
    static var pausedRequests: Int {
        gateLock.lock();defer { gateLock.unlock() };return suspended.count
    }
    static func resume() {
        gateLock.lock();let pending = suspended;suspended = [];gatedURL = nil;gateLock.unlock()
        for (protocolInstance,url,fixture) in pending { protocolInstance.finish(url,fixture:fixture) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url=request.url!, key=url.absoluteString
        Self.requests.append(key)
        Self.requestHeaders[key] = request.allHTTPHeaderFields ?? [:]
        let fixture=Self.responses[key] ?? (404,Data())
        Self.gateLock.lock()
        if Self.gatedURL == key {
            Self.suspended.append((self,url,fixture));Self.gateLock.unlock();return
        }
        Self.gateLock.unlock()
        finish(url,fixture:fixture)
    }
    private func finish(_ url: URL,fixture: (Int,Data)) {
        if fixture.0 == 0 { client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet));return }
        let response=HTTPURLResponse(url:url,statusCode:fixture.0,httpVersion:nil,headerFields:Self.responseHeaders[url.absoluteString])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:fixture.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.gateLock.lock();defer { Self.gateLock.unlock() }
        Self.suspended.removeAll { $0.0 === self }
    }
}

@main struct UpdateManagerTests {
    @MainActor static func main() async throws {
        let repo="example/buddy", tag="v2.0.0"
        let policyURL="https://github.com/\(repo)/releases/download/\(tag)/update-policy.json"
        let apiURL="https://api.github.com/repos/\(repo)/releases/latest"
        func configure(_ mode: String, corrupt: Bool=false, policyStatus: Int=200, missing: Bool=false, schemaVersion: Int=1) throws {
            let policy=try JSONSerialization.data(withJSONObject:["schemaVersion":schemaVersion,"version":"2.0.0","mode":mode])
            let hash=SHA256.hash(data:policy).map { String(format:"%02x",$0) }.joined()
            var assets:[[String:Any]]=[["name":"Codex-Buddy-2.0.0-arm64.dmg","state":"uploaded"]]
            if !missing { assets.append(["name":"update-policy.json","state":"uploaded","browser_download_url":policyURL,"digest":"sha256:"+(corrupt ? String(repeating:"0",count:64) : hash),"size":policy.count]) }
            let release:[String:Any]=["tag_name":tag,"html_url":"https://github.com/\(repo)/releases/tag/\(tag)","body":"Fixed known issues.","draft":false,"prerelease":false,"assets":assets]
            PolicyFixtureProtocol.responses=[apiURL:(200,try JSONSerialization.data(withJSONObject:release)),policyURL:(policyStatus,policy)]
            PolicyFixtureProtocol.requests=[]
        }
        try configure("notify")
        let waitSuite="buddy-transaction-update-tests-"+UUID().uuidString
        let waitDefaults=UserDefaults(suiteName:waitSuite)!
        defer { waitDefaults.removePersistentDomain(forName:waitSuite) }
        let waitConfiguration=URLSessionConfiguration.ephemeral;waitConfiguration.protocolClasses=[PolicyFixtureProtocol.self]
        var transactionGate:CheckedContinuation<Void,Never>?, didInstall=false
        let waiting=UpdateManager(defaults:waitDefaults,configuration:waitConfiguration,repository:repo,currentVersion:"1.0.0",installOperation:{ _,_ in didInstall=true })
        waiting.check(manual:true)
        for _ in 0..<500 where waiting.checking { try await Task.sleep(nanoseconds:2_000_000) }
        precondition(waiting.available != nil)
        waiting.prepareForInstallation={ await withCheckedContinuation { transactionGate=$0 } }
        waiting.installAvailable()
        for _ in 0..<500 where transactionGate == nil { try await Task.sleep(nanoseconds:2_000_000) }
        precondition(waiting.installing && waiting.status == .preparingInstallation && !didInstall)
        transactionGate?.resume();transactionGate=nil
        for _ in 0..<500 where waiting.installing { try await Task.sleep(nanoseconds:2_000_000) }
        precondition(didInstall && !waiting.installing,"Installation resumes only after the transaction barrier")
        for scenario in ["none","notify","schema2-notify","schema2-silent","silent","manual-none","manual-silent","corrupt","unavailable","missing","ignored","install-failure","manual-current","manual-ahead"] {
            let mode=scenario.contains("none") ? "none" : ["notify","schema2-notify"].contains(scenario) ? "notify" : "silent"
            try configure(mode,corrupt:scenario=="corrupt",policyStatus:scenario=="unavailable" ? 503 : 200,missing:scenario=="missing",schemaVersion:scenario.hasPrefix("schema2-") ? 2 : 1)
            let suite="buddy-policy-tests-\(UUID().uuidString)"
            let defaults=UserDefaults(suiteName:suite)!
            defer { defaults.removePersistentDomain(forName:suite) }
            if scenario=="ignored" { defaults.set([tag],forKey:"updates.ignored") }
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PolicyFixtureProtocol.self]
            var installs=0, notifications=0, installUI=0, foreground=false
            let manager=UpdateManager(defaults:defaults,configuration:config,repository:repo,currentVersion:scenario=="manual-current" ? "2.0.0" : scenario=="manual-ahead" ? "3.0.0" : "1.0.0",installOperation:{ release, silent in
                precondition(release.tagName==tag)
                installs += 1;foreground = !silent
                if scenario=="install-failure" { throw UpdateInstallFailure.verification }
            },presentation:{ _ in notifications += 1 })
            manager.beforeInstall={ installUI += 1 }
            manager.beforePresent={ preconditionFailure("Unexpected modal UI") }
            manager.check(manual:scenario.hasPrefix("manual-"))
            for _ in 0..<1000 {
                if !manager.checking && !manager.installing { break }
                try await Task.sleep(nanoseconds:5_000_000)
            }
            precondition(!manager.checking && !manager.installing,"Check did not finish")
            let shouldInstall=["silent","manual-silent","install-failure"].contains(scenario)
            precondition(installs == (shouldInstall ? 1 : 0),scenario)
            precondition(notifications == (["notify","schema2-notify","manual-none"].contains(scenario) ? 1 : 0),scenario)
            precondition(manager.showsPanelUpdate == ["notify","schema2-notify","manual-none"].contains(scenario),"Inline update visibility: \(scenario)")
            precondition(installUI==0 && !foreground,"Silent update must not show install UI")
            if scenario=="manual-current" || scenario=="manual-ahead" {
                precondition(manager.available == nil && !manager.message.isEmpty)
                precondition(!PolicyFixtureProtocol.requests.contains(policyURL))
            }
            manager.check(manual:false)
            precondition(!manager.checking,"Repeated background checks must be throttled")
            print("Update integration passed:",scenario)
        }
        try await betaChannelTests()
        try await resilienceTests()
        // Native presentation has no modal or activation hook. A verified offer
        // must survive relaunch even when its legacy announcement was recorded.
        try configure("notify")
        let suite="buddy-inline-update-tests-\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        func makeManager() -> UpdateManager {
            let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[PolicyFixtureProtocol.self]
            let value=UpdateManager(defaults:defaults,configuration:configuration,repository:repo,currentVersion:"1.0.0",
                installOperation:{ _,_ in throw UpdateInstallFailure.verification })
            value.beforePresent={ preconditionFailure("Update discovery must not request modal presentation") }
            return value
        }
        func waitFor(_ manager: UpdateManager) async throws {
            for _ in 0..<1000 {
                if !manager.checking && !manager.installing { return }
                try await Task.sleep(nanoseconds:5_000_000)
            }
            preconditionFailure("Inline check did not complete")
        }
        let first=makeManager();first.check(manual:false);try await waitFor(first)
        precondition(first.showsPanelUpdate && first.available?.tagName==tag)
        precondition(defaults.object(forKey:"updates.lastSuccessfulCheck") != nil && defaults.bool(forKey:"updates.restorePanelOffer"),"Relaunch fixture must preserve its last attempt and startup restore marker")
        let requestsBeforeRestore = PolicyFixtureProtocol.requests.count
        let restored=makeManager();restored.check(manual:false);try await waitFor(restored)
        precondition(restored.showsPanelUpdate,"Previously announced major offer must remain inline after relaunch")
        precondition(PolicyFixtureProtocol.requests.count == requestsBeforeRestore+2,"Persisted visible offer must receive a startup verification even inside the six-hour cadence")
        restored.check(manual:false)
        precondition(!restored.checking && PolicyFixtureProtocol.requests.count == requestsBeforeRestore+2,"Startup offer restoration must not bypass cadence repeatedly in the same manager")
        restored.installAvailable();precondition(restored.installing)
        try await waitFor(restored)
        precondition(restored.showsPanelUpdate && !restored.installing && restored.installFailed && !restored.message.isEmpty,"Failure keeps an inline retry")
        restored.ignoreAvailable();precondition(!restored.showsPanelUpdate)
        let ignored=makeManager();ignored.check(manual:false);try await waitFor(ignored)
        precondition(!ignored.showsPanelUpdate,"Ignored version must stay hidden after relaunch")
        ignored.check(manual:true);try await waitFor(ignored)
        precondition(ignored.showsPanelUpdate,"An explicit manual check can offer an ignored release")
        try configure("none")
        defaults.removeObject(forKey:"updates.lastSuccessfulCheck")
        let ordinary=makeManager();ordinary.check(manual:false);try await waitFor(ordinary)
        precondition(!ordinary.showsPanelUpdate,"Ordinary background updates stay quiet")
        print("Inline major-update tests passed: no modal, relaunch, ignored versions, manual checks and failure retry")

        // Pause the real policy fetch after a visible, verified offer exists.
        // A dismiss click during that suspension takes priority over the older
        // request, including a manual request and a silent-install policy.
        for manual in [false,true] {
            for mode in ["notify","silent"] {
                try configure("notify")
                let suite="buddy-update-ignore-race-\(UUID().uuidString)"
                let defaults=UserDefaults(suiteName:suite)!
                defer { defaults.removePersistentDomain(forName:suite);PolicyFixtureProtocol.resume() }
                let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[PolicyFixtureProtocol.self]
                var clock=Date(timeIntervalSince1970:1_800_000_000)
                var installs=0, callbacks=0, installUI=0
                let manager=UpdateManager(defaults:defaults,configuration:configuration,repository:repo,currentVersion:"1.0.0",
                    installOperation:{ _,_ in installs += 1 },presentation:{ _ in callbacks += 1 },now:{clock})
                manager.beforePresent={ preconditionFailure("Ignore-race fixture must never present modal UI") }
                manager.beforeInstall={ installUI += 1 }
                manager.check(manual:false);try await waitFor(manager)
                precondition(manager.showsPanelUpdate && manager.available?.tagName == tag && callbacks == 1 && installs == 0,"Seed the same manager with an existing verified offer")
                try configure(mode)
                clock = clock.addingTimeInterval(6*3_600+1)
                PolicyFixtureProtocol.pause(policyURL)
                manager.check(manual:manual)
                for _ in 0..<1_000 {
                    if PolicyFixtureProtocol.pausedRequests == 1 { break }
                    try await Task.sleep(nanoseconds:2_000_000)
                }
                precondition(manager.checking && PolicyFixtureProtocol.pausedRequests == 1,"Test must suspend exactly the in-flight policy response")
                precondition(PolicyFixtureProtocol.requests.contains(apiURL) && PolicyFixtureProtocol.requests.contains(policyURL),"Ignore must occur after API discovery and before policy completion")
                manager.ignoreAvailable()
                precondition(!manager.showsPanelUpdate && !defaults.bool(forKey:"updates.restorePanelOffer"),"Dismiss must immediately clear the visible offer and relaunch marker")
                PolicyFixtureProtocol.resume();try await waitFor(manager)
                precondition(!manager.showsPanelUpdate && !defaults.bool(forKey:"updates.restorePanelOffer"),"Completed \(manual ? "manual" : "background") \(mode) request must not resurrect a dismissed banner")
                precondition(installs == 0 && !manager.installing && installUI == 0,"Dismiss during metadata fetch must prevent silent installation")
                precondition(callbacks == 1,"Dismissed in-flight request must not call presentation again")
                precondition(defaults.stringArray(forKey:"updates.ignored")?.contains(tag) == true,"The dismiss decision must remain persisted")
                print("Update ignore-during-metadata test passed:",manual ? "manual" : "background",mode)
            }
        }
    }
    @MainActor static func betaChannelTests() async throws {
        let repo = "example/buddy"
        let latestURL = "https://api.github.com/repos/\(repo)/releases/latest"
        let listURL = "https://api.github.com/repos/\(repo)/releases?per_page=100"
        func fixture(_ version:String, mode:String, draft:Bool = false) throws -> ([String:Any],String,Data) {
            let tag = "v"+version, url = "https://github.com/\(repo)/releases/download/\(tag)/update-policy.json"
            let policy = try JSONSerialization.data(withJSONObject:["schemaVersion":1,"version":version,"mode":mode])
            let hash = SHA256.hash(data:policy).map { String(format:"%02x",$0) }.joined()
            let release:[String:Any] = ["tag_name":tag,"html_url":"https://github.com/\(repo)/releases/tag/\(tag)",
                "draft":draft,"prerelease":version.contains("-beta"),"body":"Synthetic release",
                "assets":[["name":"Codex-Buddy-\(version)-arm64.dmg","state":"uploaded"],
                          ["name":"update-policy.json","state":"uploaded","browser_download_url":url,"size":policy.count,"digest":"sha256:"+hash]]]
            return (release,url,policy)
        }
        let stable = try fixture("2.0.0",mode:"none")
        let beta1 = try fixture("2.1.0-beta.1",mode:"none")
        let beta10 = try fixture("2.1.0-beta.10",mode:"silent")
        let draft = try fixture("3.0.0-beta.1",mode:"silent",draft:true)
        func configure(_ extra:[[String:Any]] = []) throws {
            PolicyFixtureProtocol.responses = [latestURL:(200,try JSONSerialization.data(withJSONObject:stable.0)),
                listURL:(200,try JSONSerialization.data(withJSONObject:[beta1.0,draft.0,stable.0,beta10.0]+extra))]
            for item in [stable,beta1,beta10,draft] { PolicyFixtureProtocol.responses[item.1] = (200,item.2) }
            PolicyFixtureProtocol.requests = []
        }
        func wait(_ manager:UpdateManager) async throws {
            for _ in 0..<1000 {
                if !manager.checking && !manager.installing { return }
                try await Task.sleep(nanoseconds:5_000_000)
            }
            preconditionFailure("Synthetic beta check timed out")
        }
        for includeBeta in [false,true] {
            for manual in [false,true] {
                try configure()
                let suite="buddy-beta-updates-\(UUID().uuidString)", defaults=UserDefaults(suiteName:suite)!
                defer { defaults.removePersistentDomain(forName:suite) }
                if includeBeta { defaults.set(true,forKey:"updates.includesBeta") }
                let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PolicyFixtureProtocol.self]
                var installed:[String] = []
                let manager=UpdateManager(defaults:defaults,configuration:config,repository:repo,currentVersion:"1.0.0",
                    installOperation:{ release,silent in precondition(silent);installed.append(release.tagName) })
                precondition(manager.includesBeta == includeBeta,"Beta is off by default and restores explicit opt in")
                manager.check(manual:manual);try await wait(manager)
                precondition(manager.available?.tagName == (includeBeta ? "v2.1.0-beta.10" : "v2.0.0"))
                precondition(installed == (includeBeta ? ["v2.1.0-beta.10"] : []))
                precondition(PolicyFixtureProtocol.requests.contains(listURL) == includeBeta)
                if !includeBeta { precondition(!PolicyFixtureProtocol.requests.contains(beta10.1),"Beta opt out must not fetch beta metadata") }
            }
        }
        // Turning off the channel while verified silent metadata is in flight
        // must discard that result and then check the stable channel.
        try configure()
        let suite="buddy-beta-race-\(UUID().uuidString)", defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite);PolicyFixtureProtocol.resume() }
        defaults.set(true,forKey:"updates.includesBeta")
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PolicyFixtureProtocol.self]
        var installs=0
        let manager=UpdateManager(defaults:defaults,configuration:config,repository:repo,currentVersion:"1.0.0",
            installOperation:{ _,_ in installs += 1 })
        PolicyFixtureProtocol.pause(beta10.1);manager.check(manual:true)
        for _ in 0..<1000 {
            if PolicyFixtureProtocol.pausedRequests == 1 { break }
            try await Task.sleep(nanoseconds:2_000_000)
        }
        precondition(PolicyFixtureProtocol.pausedRequests == 1)
        manager.setIncludesBeta(false);PolicyFixtureProtocol.resume();try await wait(manager)
        precondition(installs == 0 && manager.available?.tagName == "v2.0.0" && !manager.includesBeta)
        let restored=UpdateManager(defaults:defaults,configuration:config,repository:repo,currentVersion:"1.0.0")
        precondition(!restored.includesBeta,"Channel choice survives relaunch")
        let finalStable = try fixture("2.1.0",mode:"none")
        try configure([finalStable.0]);PolicyFixtureProtocol.responses[finalStable.1]=(200,finalStable.2)
        PolicyFixtureProtocol.responses[latestURL]=(200,try JSONSerialization.data(withJSONObject:finalStable.0))
        manager.setIncludesBeta(true);try await wait(manager)
        precondition(manager.available?.tagName == "v2.1.0","Final stable supersedes beta of the same version")
        let disabledRelease = try JSONDecoder().decode(GitHubRelease.self,from:JSONSerialization.data(withJSONObject:beta10.0))
        precondition(disabledRelease.publishedURL(repository:repo) == nil && disabledRelease.publishedURL(repository:repo,includeBeta:true) != nil)
        precondition(UpdatePolicy.action(release:disabledRelease,mode:.silent,current:"1.0.0",manual:true,ignored:[],announced:[]) == .none)
        precondition(UpdatePolicy.action(release:disabledRelease,mode:.silent,current:"3.0.0",manual:false,ignored:[],announced:[],includeBeta:true) == .none)
        print("Beta update checks passed: default opt out, manual/background filtering, numeric sorting, stable promotion, persistence and channel-change race")
    }

    @MainActor static func resilienceTests() async throws {
        let repo="example/buddy", api="https://api.github.com/repos/example/buddy/releases/latest"
        let list="https://api.github.com/repos/example/buddy/releases?per_page=100"
        let policyURL="https://github.com/example/buddy/releases/download/v2.0.0/update-policy.json"
        func fixture(mode:String="none", percentage:Int?=nil) throws -> Data {
            var document:[String:Any]=["schemaVersion":1,"version":"2.0.0","mode":mode]
            if let percentage { document["schemaVersion"]=3;document["rolloutPercentage"]=percentage }
            let policy=try JSONSerialization.data(withJSONObject:document)
            let hash=SHA256.hash(data:policy).map { String(format:"%02x",$0) }.joined()
            let release:[String:Any]=["tag_name":"v2.0.0","html_url":"https://github.com/example/buddy/releases/tag/v2.0.0","body":"Synthetic notes","draft":false,"prerelease":false,
                "assets":[["name":"Codex-Buddy-2.0.0-arm64.dmg","state":"uploaded","browser_download_url":"https://github.com/example/buddy/releases/download/v2.0.0/Codex-Buddy-2.0.0-arm64.dmg","size":123,"digest":"sha256:"+String(repeating:"a",count:64)],
                    ["name":"update-policy.json","state":"uploaded","browser_download_url":policyURL,"size":policy.count,"digest":"sha256:"+hash]]]
            let data=try JSONSerialization.data(withJSONObject:release)
            PolicyFixtureProtocol.responses=[api:(200,data),policyURL:(200,policy)]
            PolicyFixtureProtocol.requests=[];PolicyFixtureProtocol.responseHeaders=[:];PolicyFixtureProtocol.requestHeaders=[:]
            return data
        }
        func wait(_ manager:UpdateManager) async throws {
            for _ in 0..<1000 { if !manager.checking && !manager.installing { return };try await Task.sleep(nanoseconds:5_000_000) }
            preconditionFailure("Resilience fixture timed out")
        }
        func configuration() -> URLSessionConfiguration {
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PolicyFixtureProtocol.self];return config
        }
        let suite="buddy-update-recovery-"+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        var clock=Date(timeIntervalSince1970:1_800_000_000)
        _=try fixture();PolicyFixtureProtocol.responses[api]=(0,Data())
        let first=UpdateManager(defaults:defaults,configuration:configuration(),repository:repo,currentVersion:"1.0.0",now:{clock})
        first.check(manual:false);try await wait(first)
        precondition(first.status == .failed(.network) && first.lastSuccessfulCheckAt == nil)
        precondition(first.nextRetryAt == clock.addingTimeInterval(60))
        let restored=UpdateManager(defaults:defaults,configuration:configuration(),repository:repo,currentVersion:"1.0.0",now:{clock})
        restored.check(manual:false);precondition(!restored.checking && PolicyFixtureProtocol.requests.count == 1,"Restart preserves bounded failure backoff")
        clock=clock.addingTimeInterval(61);restored.check(manual:false);try await wait(restored)
        precondition(restored.nextRetryAt == clock.addingTimeInterval(300),"Repeated failures increase backoff rather than consuming normal six-hour cadence")
        restored.networkRecovered();precondition(restored.nextRetryAt == clock)
        _=try fixture();restored.check(manual:false);try await wait(restored)
        precondition(restored.lastSuccessfulCheckAt == clock && restored.nextRetryAt == nil && restored.status == .available)
        restored.check(manual:false);precondition(!restored.checking,"Successful routine checks retain six-hour cadence")
        PolicyFixtureProtocol.responses[api]=(0,Data());restored.check(manual:true);try await wait(restored)
        precondition(restored.status == .failed(.network) && restored.lastSuccessfulCheckAt == clock,"Failure must replace stale success text, without erasing last success time")
        defaults.removePersistentDomain(forName:suite)

        _=try fixture();PolicyFixtureProtocol.responses[api]=(429,Data())
        PolicyFixtureProtocol.responseHeaders[api]=["Retry-After":"600"]
        let limited=UpdateManager(defaults:defaults,configuration:configuration(),repository:repo,currentVersion:"1.0.0",now:{clock})
        limited.check(manual:false);try await wait(limited)
        precondition(limited.status == .failed(.rateLimited) && limited.nextRetryAt == clock.addingTimeInterval(600))
        limited.check(manual:true);limited.networkRecovered();precondition(PolicyFixtureProtocol.requests.count == 1,"Manual checks and connectivity changes honor server Retry-After")
        let persistedLimit=UpdateManager(defaults:defaults,configuration:configuration(),repository:repo,currentVersion:"1.0.0",now:{clock})
        persistedLimit.check(manual:true);precondition(PolicyFixtureProtocol.requests.count == 1)
        clock=clock.addingTimeInterval(601);_=try fixture();persistedLimit.check(manual:false);try await wait(persistedLimit)
        precondition(persistedLimit.status == .available && persistedLimit.nextRetryAt == nil)
        let reset=HTTPURLResponse(url:URL(string:api)!,statusCode:403,httpVersion:nil,headerFields:["X-RateLimit-Remaining":"0","X-RateLimit-Reset":String(Int(clock.timeIntervalSince1970)+500)])!
        precondition(UpdateManager.retryDate(response:reset,now:clock) == clock.addingTimeInterval(500))
        defaults.removePersistentDomain(forName:suite)

        _=try fixture();PolicyFixtureProtocol.responseHeaders=[api:["ETag":"release-1"],policyURL:["ETag":"policy-1"]]
        let cached=UpdateManager(defaults:defaults,configuration:configuration(),repository:repo,currentVersion:"1.0.0",now:{clock})
        cached.check(manual:true);try await wait(cached)
        PolicyFixtureProtocol.responses[api]=(304,Data());PolicyFixtureProtocol.responses[policyURL]=(304,Data())
        cached.check(manual:true);try await wait(cached)
        precondition(cached.available?.tagName == "v2.0.0" && cached.status == .available)
        precondition(PolicyFixtureProtocol.requestHeaders[api]?["If-None-Match"] == "release-1")
        precondition(PolicyFixtureProtocol.requestHeaders[policyURL]?["If-None-Match"] == "policy-1")
        defaults.removePersistentDomain(forName:suite)

        let stable=try fixture();var unlisted=try JSONSerialization.jsonObject(with:stable) as! [String:Any]
        unlisted["tag_name"]="v3.0.0";unlisted["html_url"]="https://github.com/example/buddy/releases/tag/v3.0.0"
        unlisted["assets"]=[["name":"Codex-Buddy-3.0.0-arm64.dmg","state":"uploaded"]]
        PolicyFixtureProtocol.responses[list]=(200,try JSONSerialization.data(withJSONObject:[unlisted]))
        defaults.set(true,forKey:"updates.includesBeta")
        let beta=UpdateManager(defaults:defaults,configuration:configuration(),repository:repo,currentVersion:"1.0.0",now:{clock})
        beta.check(manual:true);try await wait(beta)
        precondition(beta.available?.tagName == "v2.0.0","Beta mode must not resurrect a stable version removed from Latest")
        defaults.removePersistentDomain(forName:suite)

        _=try fixture(mode:"silent",percentage:0);var installations=0
        let phased=UpdateManager(defaults:defaults,configuration:configuration(),repository:repo,currentVersion:"1.0.0",installOperation:{ _,_ in installations += 1 },now:{clock})
        phased.check(manual:false);try await wait(phased)
        precondition(installations == 0 && phased.status == .deferred && !phased.showsPanelUpdate)
        phased.check(manual:true);try await wait(phased)
        precondition(installations == 1,"Explicit checks bypass phased rollout while preserving release mode")
        phased.reportRestoredUpdate(failedVersion:"2.0.0");clock=clock.addingTimeInterval(6*3600+1)
        phased.check(manual:false);try await wait(phased)
        precondition(installations == 1,"A failed version is not automatically installed again")
        defaults.removePersistentDomain(forName:suite)

        _=try fixture();var replacements=0, stages=0
        let changed=UpdateManager(defaults:defaults,configuration:configuration(),repository:repo,currentVersion:"1.0.0",
            stagingOperation:{ _,_ in stages += 1;PolicyFixtureProtocol.responses[api]=(404,Data());return FileManager.default.temporaryDirectory },
            replacementOperation:{ _,_ in replacements += 1 },now:{clock})
        changed.check(manual:true);try await wait(changed)
        changed.installAvailable();try await wait(changed)
        precondition(stages == 1 && replacements == 0 && changed.available == nil && changed.status == .failed(.withdrawn),"Withdrawal after download must stop before replacement")
        print("Update resilience passed: failure/restart/recovery, rate limits, ETag 304, recommended stable, phased rollout and post-download withdrawal")
    }

}
