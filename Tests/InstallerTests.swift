import AppKit
import CryptoKit

final class FixtureProtocol: URLProtocol {
    static var body=Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/octet-stream","Content-Length":"\(Self.body.count)"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct InstallerTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass test DMG path") }
        let bytes=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        FixtureProtocol.body=bytes
        let digest=SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-stage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let target=folder.appendingPathComponent("Codex Buddy.app")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[FixtureProtocol.self]
        let filename=URL(fileURLWithPath:CommandLine.arguments[1]).lastPathComponent
        let version=filename.replacingOccurrences(of:"Codex-Buddy-",with:"").replacingOccurrences(of:"-arm64.dmg",with:"")
        guard AppVersion(version) != nil else { fatalError("Invalid fixture filename") }
        let includeBeta = AppVersion(version)!.isBeta
        var release=GitHubRelease(tagName:"v\(version)",htmlURL:"https://github.com/duoduocats/codex-buddy/releases/tag/v\(version)",body:"",draft:false,prerelease:false,assets:[.init(name:"\(filename)",state:"uploaded",browserDownloadURL:"https://github.com/duoduocats/codex-buddy/releases/download/v\(version)/\(filename)",digest:"sha256:\(digest)",size:bytes.count)])
        if includeBeta {
            do {
                _ = try await UpdateInstaller.stage(release:release,repository:"duoduocats/codex-buddy",target:target,configuration:config) { _ in }
                fatalError("Beta package accepted without opt in")
            } catch UpdateInstallFailure.invalid { print("Beta package rejected without opt in") }
        }
        let staged=try await UpdateInstaller.stage(release:release,repository:"duoduocats/codex-buddy",target:target,configuration:config,includeBeta:includeBeta) { _ in }
        precondition(FileManager.default.fileExists(atPath:staged.appendingPathComponent("Codex Buddy.app/Contents/MacOS/CodexBuddy").path))
        precondition(FileManager.default.fileExists(atPath:target.path))
        print("Real DMG download fixture, checksum, mount, signature and staging passed")
        release=GitHubRelease(tagName:release.tagName,htmlURL:release.htmlURL,body:nil,draft:false,prerelease:false,assets:[.init(name:release.assets[0].name,state:"uploaded",browserDownloadURL:release.assets[0].browserDownloadURL,digest:"sha256:"+String(repeating:"0",count:64),size:bytes.count)])
        do {
            _ = try await UpdateInstaller.stage(release:release,repository:"duoduocats/codex-buddy",target:target,configuration:config,includeBeta:includeBeta) { _ in }
            fatalError("Bad checksum accepted")
        } catch UpdateInstallFailure.verification { print("Tampered download rejected; target preserved") }
    }
}
