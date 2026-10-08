import Foundation
import CryptoKit

struct AppVersion: Comparable, Equatable {
    let parts: [Int]
    let beta: [Int]?
    var isBeta: Bool { beta != nil }
    init?(_ string: String) {
        let value = string.hasPrefix("v") ? String(string.dropFirst()) : string
        guard value.utf8.count <= 80 else { return nil }
        let halves = value.components(separatedBy:"-beta")
        guard halves.count <= 2 else { return nil }
        let fields = halves[0].split(separator:".",omittingEmptySubsequences:false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.map { Int($0)! }
        if halves.count == 1 { beta = nil }
        else if halves[1].isEmpty { beta = [] }
        else {
            let suffix = halves[1]
            guard suffix.hasPrefix("."), suffix.count > 1 else { return nil }
            let number = String(suffix.dropFirst())
            guard number.allSatisfy({ $0.isASCII && $0.isNumber }),
                  number == "0" || !number.hasPrefix("0"), let value = Int(number) else { return nil }
            beta = [value]
        }
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.parts != rhs.parts { return lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        switch (lhs.beta,rhs.beta) {
        case (nil,_): return false
        case (_,nil): return true
        case let (left?,right?): return left.lexicographicallyPrecedes(right)
        }
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    struct Asset: Decodable {
        let name: String
        let state: String
        var browserDownloadURL: String? = nil
        var digest: String? = nil
        var size: Int? = nil
        enum CodingKeys: String, CodingKey { case name, state, browserDownloadURL = "browser_download_url", digest, size }
    }
    func installAsset(repository: String) -> Asset? {
        let version=tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let name="Codex-Buddy-\(version)-arm64.dmg"
        return assets.first { asset in
            guard asset.name==name,asset.state=="uploaded",let size=asset.size,size>0,size<100_000_000,
                  let raw=asset.browserDownloadURL,let url=URL(string:raw) else { return false }
            return url.scheme=="https" && url.host=="github.com" && url.user==nil && url.password==nil
                && url.port==nil && url.query==nil && url.fragment==nil
                && url.path=="/\(repository)/releases/download/\(tagName)/\(name)"
        }
    }
    func policyAsset(repository: String) -> Asset? {
        let candidates = assets.filter { $0.name == "update-policy.json" }
        guard candidates.count == 1, let asset = candidates.first,
              asset.state == "uploaded", let size = asset.size, size > 0, size <= 4096,
              let raw = asset.browserDownloadURL, let url = URL(string:raw),
              url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.path == "/\(repository)/releases/download/\(tagName)/update-policy.json" else { return nil }
        return asset
    }
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", body, draft, prerelease, assets
    }
    var isImportant: Bool { (body ?? "").components(separatedBy:.newlines).contains { $0.trimmingCharacters(in:.whitespaces) == "<!-- codex-buddy:important -->" } }
    var isBeta: Bool { prerelease || AppVersion(tagName)?.isBeta == true }
    func publishedURL(repository: String, includeBeta: Bool = false) -> URL? {
        guard !draft, (includeBeta || !isBeta), AppVersion(tagName) != nil,
              let url = URL(string:htmlURL), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.path == "/\(repository)/releases/tag/\(tagName)",
              assets.contains(where:{ $0.name == "Codex-Buddy-\(tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName)-arm64.dmg" && $0.state == "uploaded" }) else { return nil }
        return url
    }
}

enum ReleaseUpdateMode: String, Codable { case none, notify, silent }
enum ReleaseUpdateAction: Equatable { case none, notify, install }

private struct ReleaseUpdateDocument: Decodable {
    let schemaVersion: Int
    let version: String
    let mode: ReleaseUpdateMode
}

enum UpdatePolicy {
    static func verifiedMode(data: Data, asset: GitHubRelease.Asset, tag: String) -> ReleaseUpdateMode? {
        guard data.count > 0, data.count <= 4096, data.count == asset.size,
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              String(digest.dropFirst(7)).lowercased() == SHA256.hash(data:data).map({ String(format:"%02x",$0) }).joined(),
              let document = try? JSONDecoder().decode(ReleaseUpdateDocument.self,from:data),
              (document.schemaVersion == 1 || (document.schemaVersion == 2 && document.mode == .notify)),
              document.version == (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag),
              AppVersion(document.version) != nil else { return nil }
        return document.mode
    }
    static func action(release: GitHubRelease, mode: ReleaseUpdateMode, current: String,
                       manual: Bool, ignored: [String], announced: [String], includeBeta: Bool = false) -> ReleaseUpdateAction {
        guard let latest = AppVersion(release.tagName), let installed = AppVersion(current),
              latest > installed, !release.draft, (includeBeta || !release.isBeta) else { return .none }
        if !manual && ignored.contains(release.tagName) { return .none }
        if mode == .silent { return .install }
        if manual { return .notify }
        return mode == .notify && !announced.contains(release.tagName) ? .notify : .none
    }
    static func latestRelease(_ releases: [GitHubRelease], repository: String, includeBeta: Bool) -> GitHubRelease? {
        releases.filter { $0.publishedURL(repository:repository,includeBeta:includeBeta) != nil }
            .max { AppVersion($0.tagName)! < AppVersion($1.tagName)! }
    }
    static func validRepository(_ value: String) -> Bool {
        value.range(of:#"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#,options:.regularExpression) != nil
    }
    static func shouldNotify(release: GitHubRelease, current: String, ignored: [String], announced: [String]) -> Bool {
        guard let latest = AppVersion(release.tagName), let installed = AppVersion(current) else { return false }
        return latest > installed && release.isImportant && !release.draft && !release.isBeta
            && !ignored.contains(release.tagName) && !announced.contains(release.tagName)
    }
}
