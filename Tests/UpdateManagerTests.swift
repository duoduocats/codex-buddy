import AppKit
import CryptoKit

final class PolicyFixtureProtocol: URLProtocol {
    static var responses: [String: (Int,Data)] = [:]
    static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url=request.url!, key=url.absoluteString
        Self.requests.append(key)
        let fixture=Self.responses[key] ?? (404,Data())
        let response=HTTPURLResponse(url:url,statusCode:fixture.0,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:fixture.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct UpdateManagerTests {
    @MainActor static func main() async throws {
        let repo="example/buddy", tag="v2.0.0"
        let policyURL="https://github.com/\(repo)/releases/download/\(tag)/update-policy.json"
        let apiURL="https://api.github.com/repos/\(repo)/releases/latest"
        func configure(_ mode: String, corrupt: Bool=false, policyStatus: Int=200, missing: Bool=false) throws {
            let policy=try JSONSerialization.data(withJSONObject:["schemaVersion":1,"version":"2.0.0","mode":mode])
            let hash=SHA256.hash(data:policy).map { String(format:"%02x",$0) }.joined()
            var assets:[[String:Any]]=[["name":"Codex-Buddy-2.0.0-arm64.dmg","state":"uploaded"]]
            if !missing { assets.append(["name":"update-policy.json","state":"uploaded","browser_download_url":policyURL,"digest":"sha256:"+(corrupt ? String(repeating:"0",count:64) : hash),"size":policy.count]) }
            let release:[String:Any]=["tag_name":tag,"html_url":"https://github.com/\(repo)/releases/tag/\(tag)","body":"Fixed known issues.","draft":false,"prerelease":false,"assets":assets]
            PolicyFixtureProtocol.responses=[apiURL:(200,try JSONSerialization.data(withJSONObject:release)),policyURL:(policyStatus,policy)]
            PolicyFixtureProtocol.requests=[]
        }
        for scenario in ["none","notify","silent","manual-none","manual-silent","corrupt","unavailable","missing","ignored","install-failure","manual-current","manual-ahead"] {
            let mode=scenario.contains("none") ? "none" : scenario=="notify" ? "notify" : "silent"
            try configure(mode,corrupt:scenario=="corrupt",policyStatus:scenario=="unavailable" ? 503 : 200,missing:scenario=="missing")
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
            precondition(notifications == (["notify","manual-none"].contains(scenario) ? 1 : 0),scenario)
            precondition(installUI==0 && !foreground,"Silent update must not show install UI")
            if scenario=="manual-current" || scenario=="manual-ahead" {
                precondition(manager.available == nil && !manager.message.isEmpty)
                precondition(!PolicyFixtureProtocol.requests.contains(policyURL))
            }
            manager.check(manual:false)
            precondition(!manager.checking,"Repeated background checks must be throttled")
            print("Update integration passed:",scenario)
        }
    }
}
