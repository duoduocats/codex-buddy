import Foundation
import CryptoKit
let fixture = Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":32,"limit_window_seconds":18000,"reset_at":15400},"secondary_window":null},"additional_rate_limits":[{"metered_feature":"extra","limit_name":"Extra","rate_limit":{"primary_window":{"used_percent":110,"limit_window_seconds":604800,"reset_at":20000}}}],"rate_limit_reset_credits":{"available_count":2}}"#.utf8)
MainActor.assumeIsolated {
    do {
        let result = try UsageClient.decode(fixture)
        precondition(result.buckets.count == 2)
        precondition(result.rateLimits?.primary?.remaining == 68)
        precondition(result.rateLimits?.primary?.windowDurationMins == 300)
        precondition(result.rateLimits?.primary?.resetDate == Date(timeIntervalSince1970:15400))
        precondition(result.rateLimits?.secondary == nil)
        precondition(result.rateLimitsByLimitId?["extra"]?.primary?.remaining == 0)
        precondition(result.rateLimitResetCredits?.availableCount == 2)
        let absent = try UsageClient.decode(Data(#"{"plan_type":"free","rate_limit":null}"#.utf8))
        precondition(absent.rateLimitResetCredits == nil && absent.rateLimits?.primary == nil)
        do { _ = try UsageClient.decode(Data(#"{"unexpected":true}"#.utf8));fatalError("Invalid response accepted") }
        catch UsageFailure.malformed { }
        print("Native API mapping tests passed")
    } catch { fatalError("Mapping test failed: \(error)") }
}

func release(_ tag: String = "v2.0.0", body: String = "", draft: Bool = false, prerelease: Bool = false, url: String = "https://github.com/example/buddy/releases/tag/v2.0.0") -> GitHubRelease {
    GitHubRelease(tagName:tag,htmlURL:url,body:body,draft:draft,prerelease:prerelease,
        assets:[.init(name:"Codex-Buddy-2.0.0-arm64.dmg",state:"uploaded")])
}
precondition(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
precondition(AppVersion("v2.0.0")! > AppVersion("1.99.99")!)
for invalid in ["1.0", "1.0.0-beta", "1..0", "1.0.-1", "garbage", "9999999999999999999999999.0.0"] { precondition(AppVersion(invalid) == nil) }
precondition(!UpdatePolicy.shouldNotify(release:release(),current:"1.0.0",ignored:[],announced:[]),"Major version number alone must stay silent")
let important = release(body:"<!-- codex-buddy:important -->\nNotes")
precondition(UpdatePolicy.shouldNotify(release:important,current:"1.0.0",ignored:[],announced:[]))
precondition(!UpdatePolicy.shouldNotify(release:important,current:"2.0.0",ignored:[],announced:[]))
precondition(!UpdatePolicy.shouldNotify(release:important,current:"3.0.0",ignored:[],announced:[]))
precondition(!UpdatePolicy.shouldNotify(release:important,current:"1.0.0",ignored:["v2.0.0"],announced:[]))
precondition(!UpdatePolicy.shouldNotify(release:important,current:"1.0.0",ignored:[],announced:["v2.0.0"]))
precondition(!UpdatePolicy.shouldNotify(release:release(body:"<!-- codex-buddy:important -->",prerelease:true),current:"1.0.0",ignored:[],announced:[]))
precondition(important.publishedURL(repository:"example/buddy") != nil)
precondition(important.publishedURL(repository:"someone/else") == nil)
precondition(release(url:"https://github.com.evil.test/example/buddy/releases/tag/v2.0.0").publishedURL(repository:"example/buddy") == nil)
precondition(release(url:"http://github.com/example/buddy/releases/tag/v2.0.0").publishedURL(repository:"example/buddy") == nil)
precondition(release(draft:true).publishedURL(repository:"example/buddy") == nil)
precondition(UpdatePolicy.validRepository("example/codex-buddy"))
precondition(!UpdatePolicy.validRepository("https://github.com/example/buddy"))
precondition(!UpdatePolicy.validRepository("../buddy"))
print("Update version, notification and origin policy tests passed")
let assetFixture=Data(#"{"tag_name":"v2.0.0","html_url":"https://github.com/example/buddy/releases/tag/v2.0.0","body":"<!-- codex-buddy:important -->","draft":false,"prerelease":false,"assets":[{"name":"Codex-Buddy-2.0.0-arm64.dmg","state":"uploaded","browser_download_url":"https://github.com/example/buddy/releases/download/v2.0.0/Codex-Buddy-2.0.0-arm64.dmg","size":12345,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#.utf8)
let assetRelease=try JSONDecoder().decode(GitHubRelease.self,from:assetFixture)
precondition(assetRelease.installAsset(repository:"example/buddy")?.size == 12345)
precondition(assetRelease.installAsset(repository:"someone/else") == nil)
precondition(release().installAsset(repository:"example/buddy") == nil)
print("Release asset decoding and download-origin tests passed")

let fixedNow = Date(timeIntervalSince1970: 1000)
for timestamp in [Double.infinity, -Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
    precondition(LimitWindow(usedPercent:0,windowDurationMins:nil,resetsAt:timestamp).countdown(now:fixedNow) == "—")
}
precondition(RefreshPolicy.interval(failures:0) == 60)
precondition(RefreshPolicy.interval(failures:1) == 120)
precondition(RefreshPolicy.interval(failures:100) == 960)
precondition(RefreshPolicy.interval(failures:-1) == 60)
print("Malformed timestamp and bounded retry tests passed")

precondition(AppLanguage.isChinese(["zh-Hans", "en-US"]))
precondition(!AppLanguage.isChinese(["en-GB", "zh-Hans"]))
precondition(AppLanguage.isChinese(["fr-FR", "zh-Hant"]))
precondition(!AppLanguage.isChinese(["de-DE"]))
precondition(!AppLanguage.isChinese([]))
print("System language selection tests passed")

for (seconds, expected) in [(0.0,"0h"),(3599,"<1h"),(3600,"1h"),(86399,"23h"),(86400,"1d 0h"),(198000,"2d 7h")] {
    precondition(LimitWindow(usedPercent:1,windowDurationMins:300,resetsAt:1000+seconds).detailCountdown(now:Date(timeIntervalSince1970:1000)) == expected)
}
print("Detailed countdown hour-boundary tests passed")

// Menu and detail must agree on completed days/hours at unit boundaries.
for (seconds, menu, detail) in [(396000.0,"4d","4d 14h"),(431999,"4d","4d 23h"),(432000,"5d","5d 0h"),(86399,"23h","23h"),(86400,"1d","1d 0h"),(7199,"1h","1h"),(3600,"1h","1h"),(3599,"60m","<1h")] {
    let window = LimitWindow(usedPercent:0,windowDurationMins:nil,resetsAt:1000+seconds)
    precondition(window.countdown(now:fixedNow) == menu)
    precondition(window.detailCountdown(now:fixedNow) == detail)
}
print("Menu/detail countdown consistency tests passed")

for mode in [ReleaseUpdateMode.none, .notify, .silent] {
    let policyData = try JSONSerialization.data(withJSONObject:["schemaVersion":1,"version":"2.0.0","mode":mode.rawValue])
    let digest = SHA256.hash(data:policyData).map { String(format:"%02x",$0) }.joined()
    let asset = GitHubRelease.Asset(name:"update-policy.json",state:"uploaded",browserDownloadURL:"https://github.com/example/buddy/releases/download/v2.0.0/update-policy.json",digest:"sha256:"+digest,size:policyData.count)
    precondition(UpdatePolicy.verifiedMode(data:policyData,asset:asset,tag:"v2.0.0") == mode)
    precondition(UpdatePolicy.verifiedMode(data:policyData,asset:asset,tag:"v2.0.1") == nil)
    precondition(UpdatePolicy.verifiedMode(data:policyData+Data([0]),asset:asset,tag:"v2.0.0") == nil)
    let configured = GitHubRelease(tagName:"v2.0.0",htmlURL:important.htmlURL,body:nil,draft:false,prerelease:false,assets:[asset])
    precondition(configured.policyAsset(repository:"example/buddy") != nil)
    precondition(configured.policyAsset(repository:"someone/else") == nil)
    let duplicated = GitHubRelease(tagName:"v2.0.0",htmlURL:important.htmlURL,body:nil,draft:false,prerelease:false,assets:[asset,asset])
    precondition(duplicated.policyAsset(repository:"example/buddy") == nil)
    for version in ["2.0.0","3.0.0"] {
        precondition(UpdatePolicy.action(release:release(),mode:mode,current:version,manual:false,ignored:[],announced:[]) == .none)
    }
    for invalid in [release(draft:true),release(prerelease:true)] {
        precondition(UpdatePolicy.action(release:invalid,mode:mode,current:"1.0.0",manual:true,ignored:[],announced:[]) == .none)
    }
    precondition(UpdatePolicy.action(release:release(),mode:mode,current:"1.0.0",manual:false,ignored:["v2.0.0"],announced:[]) == .none)
}
precondition(UpdatePolicy.action(release:release(),mode:.notify,current:"1.0.0",manual:false,ignored:[],announced:["v2.0.0"]) == .none)
let inlinePolicy = try JSONSerialization.data(withJSONObject:["schemaVersion":2,"version":"2.1.0","mode":"notify"])
let inlineDigest = SHA256.hash(data:inlinePolicy).map { String(format:"%02x",$0) }.joined()
let inlineAsset = GitHubRelease.Asset(name:"update-policy.json",state:"uploaded",digest:"sha256:"+inlineDigest,size:inlinePolicy.count)
precondition(UpdatePolicy.verifiedMode(data:inlinePolicy,asset:inlineAsset,tag:"v2.1.0") == .notify)
let badDocuments: [[String:Any]] = [["schemaVersion":2,"version":"2.0.0","mode":"silent"],["schemaVersion":1,"version":"2.0.0","mode":"unknown"]]
for badDocument in badDocuments {
    let data = try JSONSerialization.data(withJSONObject:badDocument)
    let digest = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    let asset = GitHubRelease.Asset(name:"update-policy.json",state:"uploaded",digest:"sha256:"+digest,size:data.count)
    precondition(UpdatePolicy.verifiedMode(data:data,asset:asset,tag:"v2.0.0") == nil)
}
print("Release policy integrity and action tests passed")
