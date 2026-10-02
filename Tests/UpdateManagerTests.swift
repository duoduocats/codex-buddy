import AppKit
import CryptoKit

final class PolicyFixtureProtocol: URLProtocol {
    static var responses: [String: (Int,Data)] = [:]
    static var requests: [String] = []
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
        let fixture=Self.responses[key] ?? (404,Data())
        Self.gateLock.lock()
        if Self.gatedURL == key {
            Self.suspended.append((self,url,fixture));Self.gateLock.unlock();return
        }
        Self.gateLock.unlock()
        finish(url,fixture:fixture)
    }
    private func finish(_ url: URL,fixture: (Int,Data)) {
        let response=HTTPURLResponse(url:url,statusCode:fixture.0,httpVersion:nil,headerFields:nil)!
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
        precondition(defaults.object(forKey:"updates.lastAttempt") != nil && defaults.bool(forKey:"updates.restorePanelOffer"),"Relaunch fixture must preserve its last attempt and startup restore marker")
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
        defaults.removeObject(forKey:"updates.lastAttempt")
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
}
