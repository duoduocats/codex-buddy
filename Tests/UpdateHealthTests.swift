import Foundation

@main struct UpdateHealthTests {
    static func main() throws {
        let fm=FileManager.default, parent=fm.temporaryDirectory.appendingPathComponent("buddy-health-test-\(UUID().uuidString)")
        try fm.createDirectory(at:parent,withIntermediateDirectories:true);defer { try? fm.removeItem(at:parent) }
        let target=parent.appendingPathComponent("Codex Buddy.app"), work=parent.appendingPathComponent(".codex-buddy-update-test.noindex")
        try fm.createDirectory(at:target,withIntermediateDirectories:false);try fm.createDirectory(at:work,withIntermediateDirectories:false)
        let token=UUID().uuidString, args=["Buddy","--update-work",work.path,"--update-token",token]
        let request:[String:String]=["token":token,"target":target.path,"version":"2.0.0"]
        try JSONSerialization.data(withJSONObject:request).write(to:work.appendingPathComponent("health-request.json"))
        precondition(!UpdateHealth.acknowledge(arguments:args,bundleURL:target,version:"1.0.0"))
        precondition(!UpdateHealth.acknowledge(arguments:["Buddy","--update-work",work.path,"--update-token",UUID().uuidString],bundleURL:target,version:"2.0.0"))
        precondition(!UpdateHealth.acknowledge(arguments:args,bundleURL:parent.appendingPathComponent("Other.app"),version:"2.0.0"))
        precondition(UpdateHealth.acknowledge(arguments:args,bundleURL:target,version:"2.0.0",processID:1234))
        let receipt=try String(contentsOf:work.appendingPathComponent("ready"),encoding:.utf8)
        precondition(receipt == token+" 1234\n")
        precondition(!UpdateHealth.acknowledge(arguments:args,bundleURL:target,version:"2.0.0",processID:1234),"Never overwrite an existing receipt")
        try fm.removeItem(at:work.appendingPathComponent("ready"))
        precondition(UpdateHealth.acknowledge(arguments:args,bundleURL:URL(fileURLWithPath:target.path,isDirectory:true),version:"2.0.0",processID:1234),"NSBundle directory URLs must match the same app path")
        let restored=["Buddy","--update-restored",work.path,"--update-token",token]
        precondition(UpdateHealth.restoredVersion(arguments:restored,bundleURL:target) == nil)
        try fm.createDirectory(at:work.appendingPathComponent("failed.app"),withIntermediateDirectories:false)
        try Data("Update failed; previous version restored\n".utf8).write(to:work.appendingPathComponent("result.txt"))
        precondition(UpdateHealth.restoredVersion(arguments:restored,bundleURL:target) == "2.0.0")
        let link=parent.appendingPathComponent(".codex-buddy-update-link.noindex")
        try fm.createSymbolicLink(at:link,withDestinationURL:work)
        precondition(!UpdateHealth.acknowledge(arguments:["Buddy","--update-work",link.path,"--update-token",token],bundleURL:target,version:"2.0.0"))
        print("Update health receipts passed: exact target/version/token, no overwrite, rollback report and symlink rejection")
    }
}
