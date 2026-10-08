import AppKit
import CryptoKit

private final class ReleaseDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten >= 100_000_000 || totalBytesExpectedToWrite >= 100_000_000 { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        guard let url = request.url, url.scheme == "https", let host = url.host, allowed.contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { completionHandler(nil);return }
        completionHandler(request)
    }
}

enum UpdateInstallFailure: LocalizedError {
    case invalid, notWritable, download, verification
    var errorDescription: String? {
        switch self {
        case .invalid: return L("发布包信息不完整，暂时无法自动更新。", "Release information is incomplete. Automatic update is unavailable.")
        case .notWritable: return L("当前安装位置不可写。请将应用放入你有写入权限的 Applications 文件夹后重试。", "This installation location is not writable. Move the app to an Applications folder you can write to and try again.")
        case .download: return L("下载失败，请检查网络后重试。", "Download failed. Check your connection and try again.")
        case .verification: return L("更新包校验失败，当前版本未被替换。", "Update verification failed. Your current version has not been replaced.")
        }
    }
}

enum UpdateInstaller {
    static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            let process = Process()
            process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments
            process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            process.terminationHandler = { task in
                if task.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing:UpdateInstallFailure.verification) }
            }
            do { try process.run() }
            catch { process.terminationHandler=nil;continuation.resume(throwing:error);return }
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+90) {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+5) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }
    static func stage(release: GitHubRelease, repository: String, target: URL,
                      configuration: URLSessionConfiguration = .ephemeral, includeBeta: Bool = false,
                      progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        guard release.publishedURL(repository:repository,includeBeta:includeBeta) != nil,
              let asset=release.installAsset(repository:repository),let downloadURL=URL(string:asset.browserDownloadURL ?? ""),
              let digest=asset.digest, digest.hasPrefix("sha256:") else { throw UpdateInstallFailure.invalid }
        let expected=String(digest.dropFirst(7)).lowercased()
        guard expected.count==64, expected.allSatisfy({ $0.isHexDigit }),
              target.pathExtension=="app", FileManager.default.isWritableFile(atPath:target.deletingLastPathComponent().path),
              !target.path.hasPrefix("/Volumes/") else { throw UpdateInstallFailure.notWritable }
        let work=target.deletingLastPathComponent().appendingPathComponent(".codex-buddy-update-\(UUID().uuidString).noindex")
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let mount=work.appendingPathComponent("mount")
        var mounted=false
        do {
            let delegate=ReleaseDownloadDelegate()
            let config=configuration
            config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=300
            config.urlCache=nil;config.httpCookieStorage=nil
            let session=URLSession(configuration:config,delegate:delegate,delegateQueue:nil)
            defer { session.invalidateAndCancel() }
            await progress(L("正在下载更新…", "Downloading update…"))
            let (temp,response)=try await session.download(from:downloadURL)
            guard let http=response as? HTTPURLResponse,http.statusCode==200 else { throw UpdateInstallFailure.download }
            let dmg=work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at:temp,to:dmg)
            let size=(try FileManager.default.attributesOfItem(atPath:dmg.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size>0, size==asset.size, size<100_000_000 else { throw UpdateInstallFailure.verification }
            await progress(L("正在校验更新包…", "Verifying update…"))
            let bytes=try Data(contentsOf:dmg,options:.mappedIfSafe)
            let actual=SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
            guard actual==expected else { throw UpdateInstallFailure.verification }
            try FileManager.default.createDirectory(at:mount,withIntermediateDirectories:false)
            try await run("/usr/bin/hdiutil",["attach","-readonly","-nobrowse","-noautoopen","-mountpoint",mount.path,dmg.path])
            mounted=true
            let app=mount.appendingPathComponent("Codex Buddy.app")
            let version=release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard let info=NSDictionary(contentsOf:app.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == "com.duoduocat.codexbuddy",
                  info["CFBundleShortVersionString"] as? String == version,
                  info["CFBundleExecutable"] as? String == "CodexBuddy" else { throw UpdateInstallFailure.verification }
            if let minimum=info["LSMinimumSystemVersion"] as? String {
                let os=ProcessInfo.processInfo.operatingSystemVersion
                let installedOS="\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                guard minimum.compare(installedOS,options:.numeric) != .orderedDescending else { throw UpdateInstallFailure.verification }
            }
            // This app has no symlinks/framework bundles; reject escaping links in a release.
            try rejectSymlinks(in:app)
            try await run("/usr/bin/codesign",["--verify","--deep","--strict",app.path])
            let staged=work.appendingPathComponent("Codex Buddy.app")
            try await run("/usr/bin/ditto",[app.path,staged.path])
            try await run("/usr/bin/codesign",["--verify","--deep","--strict",staged.path])
            try await run("/usr/bin/hdiutil",["detach",mount.path]);mounted=false
            try FileManager.default.removeItem(at:dmg)
            try FileManager.default.removeItem(at:mount)
            return work
        } catch {
            if mounted { try? await run("/usr/bin/hdiutil",["detach",mount.path]) }
            // Never recursively delete a directory while a disk image remains mounted.
            if !FileManager.default.fileExists(atPath:mount.appendingPathComponent("Codex Buddy.app").path) { try? FileManager.default.removeItem(at:work) }
            throw error
        }
    }
    private static func rejectSymlinks(in app: URL) throws {
        guard try app.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw UpdateInstallFailure.verification }
        guard let files=FileManager.default.enumerator(at:app,includingPropertiesForKeys:[.isSymbolicLinkKey]) else { throw UpdateInstallFailure.verification }
        for case let file as URL in files {
            if try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == true { throw UpdateInstallFailure.verification }
        }
    }
    @MainActor static func replaceAndRelaunch(staged work: URL, target: URL, background: Bool = false) throws {
        guard let script=Bundle.main.url(forResource:"install-update",withExtension:"sh") else { throw UpdateInstallFailure.invalid }
        let localScript=work.appendingPathComponent("install-update.sh")
        try FileManager.default.copyItem(at:script,to:localScript)
        let task=Process();task.executableURL=URL(fileURLWithPath:"/bin/bash")
        task.arguments=[localScript.path,work.path,target.path,String(ProcessInfo.processInfo.processIdentifier), background ? "background" : "foreground"]
        task.standardInput=FileHandle.nullDevice;task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
        try task.run()
        NSApp.terminate(nil)
    }
}
