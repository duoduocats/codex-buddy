import Foundation

/// A local receipt proves this exact replacement process reached application initialization.
/// No network response or account data participates in this acknowledgement.
enum UpdateHealth {
    static func restoredVersion(arguments: [String], bundleURL: URL) -> String? {
        guard let index=arguments.firstIndex(of:"--update-restored"), index+1 < arguments.count,
              let tokenIndex=arguments.firstIndex(of:"--update-token"), tokenIndex+1 < arguments.count else { return nil }
        let work=URL(fileURLWithPath:arguments[index+1]).standardizedFileURL, target=bundleURL.standardizedFileURL
        guard let request=request(in:work,target:target,token:arguments[tokenIndex+1]),
              FileManager.default.fileExists(atPath:work.appendingPathComponent("failed.app").path),
              let result=try? String(contentsOf:work.appendingPathComponent("result.txt"),encoding:.utf8),
              result == "Update failed; previous version restored\n" else { return nil }
        return request["version"]
    }
    static func acknowledge(arguments: [String], bundleURL: URL, version: String,
                            processID: Int32 = ProcessInfo.processInfo.processIdentifier) -> Bool {
        guard let workIndex=arguments.firstIndex(of:"--update-work"), workIndex+1 < arguments.count,
              let tokenIndex=arguments.firstIndex(of:"--update-token"), tokenIndex+1 < arguments.count else { return false }
        let work=URL(fileURLWithPath:arguments[workIndex+1]).standardizedFileURL
        let token=arguments[tokenIndex+1], target=bundleURL.standardizedFileURL
        guard processID > 0, let request=request(in:work,target:target,token:token), request["version"] == version else { return false }
        let receipt=work.appendingPathComponent("ready")
        guard !FileManager.default.fileExists(atPath:receipt.path) else { return false }
        do {
            try Data("\(token) \(processID)\n".utf8).write(to:receipt,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receipt.path)
            return true
        } catch { return false }
    }
    private static func request(in work: URL, target: URL, token: String) -> [String:String]? {
        guard UUID(uuidString:token) != nil,
              work.deletingLastPathComponent().resolvingSymlinksInPath().path == target.deletingLastPathComponent().resolvingSymlinksInPath().path,
              target.lastPathComponent == "Codex Buddy.app",
              work.lastPathComponent.hasPrefix(".codex-buddy-update-"), work.lastPathComponent.hasSuffix(".noindex"),
              (try? work.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == false else { return nil }
        let requestURL=work.appendingPathComponent("health-request.json")
        guard let attributes=try? FileManager.default.attributesOfItem(atPath:requestURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size=attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 2048,
              let data=try? Data(contentsOf:requestURL),
              let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:String],
              request["token"] == token, request["version"] != nil, let requestedTarget=request["target"],
              URL(fileURLWithPath:requestedTarget).resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path else { return nil }
        return request
    }
}
