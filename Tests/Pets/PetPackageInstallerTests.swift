import Foundation
import AppKit
import Darwin

enum PetPackageInstallerTests {
    private enum Injected:Error { case failure }
    // The caller supplies a temporary test root and a synthetic 1536 x 2288 PNG/WebP.
    // This suite never resolves or writes an actual Codex home directory.
    static func run(root:URL,sprite:Data) throws {
        childLockProbeIfRequested()
        let fm=FileManager.default
        let workspace=root.appendingPathComponent("package-installer-tests-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:workspace,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:workspace) }
        var package=PetPackageInstaller.Package(sourceID:"synthetic-source",remoteID:"synthetic-cat",
            name:"  Synthetic Cat  ",description:"Test only",author:"Synthetic Author",license:"CC0\nSynthetic attribution",
            sourceURL:URL(string:"https://example.com/themes/cat")!,imageURL:URL(string:"https://example.com/spritesheet.png")!,
            spriteVersionNumber:2,spriteData:sprite)
        let installer=PetPackageInstaller()
        func directory(_ name:String) throws -> URL {
            let path=workspace.appendingPathComponent(name,isDirectory:true)
            try fm.createDirectory(at:path,withIntermediateDirectories:false)
            return path
        }
        func data(_ url:URL,_ name:String) throws -> Data { try Data(contentsOf:url.appendingPathComponent(name)) }
        func rejects(_ body:() throws -> Void) {
            do { try body();preconditionFailure("Synthetic unsafe installation must fail") } catch {}
        }
        func has(_ url:URL) -> Bool { fm.fileExists(atPath:url.path) }
        let firstRoot=try directory("first")
        let missingRoot=workspace.appendingPathComponent("first-time-pets",isDirectory:true)
        precondition(!has(missingRoot))
        precondition(try! installer.status(of:package,in:missingRoot) == .absent)
        precondition(!has(missingRoot),"Status queries must not create a destination")
        let missing=try installer.install(package,in:missingRoot)
        precondition(has(missing.directory))
        let permissions=try fm.attributesOfItem(atPath:missingRoot.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue & 0o777 == 0o700,"A newly created destination must be private")
        let first=try installer.install(package,in:firstRoot)
        precondition(first.backupDirectory==nil && first.directory.lastPathComponent==package.folderID)
        precondition(try! installer.status(of:package,in:firstRoot) == .current)
        precondition(PetPackageInstaller.recordedIdentity(in:first.directory) == .init(sourceID:package.sourceID,remoteID:package.remoteID))
        precondition(package.folderID.hasPrefix("codex-pets-") && !package.folderID.contains("/"))
        let manifest=try JSONSerialization.jsonObject(with:data(first.directory,"pet.json")) as! [String:Any]
        precondition(manifest["displayName"] as? String=="Synthetic Cat" && manifest["spriteVersionNumber"] as? Int==2)
        let spriteName=manifest["spritesheetPath"] as! String
        precondition(try! data(first.directory,spriteName)==sprite,"Installer must retain original image bytes")
        let attribution=try JSONSerialization.jsonObject(with:data(first.directory,"codex-pets-source.json")) as! [String:Any]
        precondition(attribution["license"] as? String==package.license && attribution["sourceID"] as? String==package.sourceID)
        let originalManifest=try data(first.directory,"pet.json")
        rejects { _=try installer.install(package,in:firstRoot) }
        precondition(try! data(first.directory,"pet.json")==originalManifest)
        var otherSource=package;otherSource.sourceID="different-source"
        precondition(otherSource.folderID != package.folderID)
        _=try installer.install(otherSource,in:firstRoot)
        var versionOne=package;versionOne.remoteID="synthetic-v1";versionOne.spriteVersionNumber=1
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1536,pixelsHigh:1872,bitsPerSample:8,
            samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:1536*4,bitsPerPixel:32)!
        versionOne.spriteData=bitmap.representation(using:.png,properties:[:])!
        let v1=try installer.install(versionOne,in:firstRoot)
        precondition(try! data(v1.directory,"spritesheet.png")==versionOne.spriteData)
        var a=package;a.sourceID="ab";a.remoteID="c"
        var b=package;b.sourceID="a";b.remoteID="bc"
        precondition(a.folderID != b.folderID,"Source identities must not concatenate ambiguously")
        package.name="Replacement Cat"
        precondition(try! installer.status(of:package,in:firstRoot) == .update)
        let replacement=try installer.install(package,in:firstRoot,replacingOwnedPackage:true)
        precondition(try! data(replacement.backupDirectory!,"pet.json")==originalManifest,"Replacements must retain prior owned packages")
        precondition(replacement.backupDirectory!.path.contains("/.codex-pets-staging/"))
        precondition(!has(firstRoot.appendingPathComponent(".codex-pets-staging/pet.json")),"Loader must not discover staged/backup packages as pets")
        var busy=PetPackageInstaller()
        busy.checkpoint={ step in
            if step == .staged {
                do { _=try installer.install(package,in:firstRoot,replacingOwnedPackage:true);preconditionFailure("Overlapping installations must not interleave") }
                catch PetPackageInstaller.Failure.busy {}
                do { _=try installer.status(of:package,in:firstRoot);preconditionFailure("Status must not see an intermediate transaction") }
                catch PetPackageInstaller.Failure.busy {}
                try checkProcessLock(firstRoot.appendingPathComponent(".codex-pets-staging/.install.lock"),shouldAcquire:false)
            }
        }
        _=try busy.install(package,in:firstRoot,replacingOwnedPackage:true)
        let lockFile=firstRoot.appendingPathComponent(".codex-pets-staging/.install.lock")
        precondition(has(lockFile),"The lock file must retain its inode between transactions")
        try checkProcessLock(lockFile,shouldAcquire:true)
        _=try installer.install(package,in:firstRoot,replacingOwnedPackage:true)

        for step in PetPackageInstaller.Checkpoint.allCases {
            let testRoot=try directory("replace-"+String(describing:step))
            var previous=package;previous.name="Prior Cat"
            let installed=try installer.install(previous,in:testRoot)
            let priorBytes=try data(installed.directory,"pet.json")
            var fault=PetPackageInstaller();fault.checkpoint={ if $0==step { throw Injected.failure } }
            rejects { _=try fault.install(package,in:testRoot,replacingOwnedPackage:true) }
            precondition(try! data(installed.directory,"pet.json")==priorBytes,"Every injected replacement failure must restore the original package")
            precondition(try! data(installed.directory,spriteName)==sprite)
            let staging=testRoot.appendingPathComponent(".codex-pets-staging",isDirectory:true)
            precondition(!has(staging.appendingPathComponent("pet.json")))
            if step == .afterCommit {
                let retained=try fm.contentsOfDirectory(at:staging,includingPropertiesForKeys:nil)
                precondition(retained.contains { has($0.appendingPathComponent("failed-new/pet.json")) },"Rollback must retain displaced new data")
            }
            let emptyRoot=try directory("new-"+String(describing:step))
            rejects { _=try fault.install(package,in:emptyRoot) }
            precondition(!has(emptyRoot.appendingPathComponent(package.folderID)),"Failed new installation must not leave a discoverable package")
        }

        let racedRoot=try directory("new-collision-after-backup")
        let racedPrior=try installer.install(package,in:racedRoot)
        let racedBytes=try data(racedPrior.directory,"pet.json")
        var race=PetPackageInstaller()
        race.checkpoint={ step in
            if step == .afterBackup {
                try fm.createDirectory(at:racedPrior.directory,withIntermediateDirectories:false)
                try Data("Synthetic collision".utf8).write(to:racedPrior.directory.appendingPathComponent("notes.txt"))
            }
        }
        do {
            _=try race.install(package,in:racedRoot,replacingOwnedPackage:true)
            preconditionFailure("A new collision must block installation and rollback")
        } catch PetPackageInstaller.Failure.rollbackFailed(let backup,_) {
            precondition(backup != nil && (try! data(backup!,"pet.json"))==racedBytes,"An obstructed rollback must retain the old backup")
            precondition(try! data(racedPrior.directory,"notes.txt")==Data("Synthetic collision".utf8),"Rollback must preserve unrelated data")
        }

        let unrelatedRoot=try directory("unrelated")
        let unrelated=unrelatedRoot.appendingPathComponent(package.folderID,isDirectory:true)
        try fm.createDirectory(at:unrelated,withIntermediateDirectories:false)
        let personal=Data("Synthetic unrelated data".utf8)
        try personal.write(to:unrelated.appendingPathComponent("notes.txt"))
        rejects { _=try installer.install(package,in:unrelatedRoot,replacingOwnedPackage:true) }
        precondition(try! installer.status(of:package,in:unrelatedRoot) == .unrelated)
        precondition(PetPackageInstaller.recordedIdentity(in:unrelated)==nil)
        precondition(try! data(unrelated,"notes.txt")==personal)
        let editedRoot=try directory("edited")
        let edited=try installer.install(package,in:editedRoot)
        try personal.write(to:edited.directory.appendingPathComponent("notes.txt"))
        rejects { _=try installer.install(package,in:editedRoot,replacingOwnedPackage:true) }
        precondition(try! data(edited.directory,"notes.txt")==personal)

        let outside=try directory("outside")
        let symlinkRoot=workspace.appendingPathComponent("linked-root",isDirectory:true)
        try fm.createSymbolicLink(at:symlinkRoot,withDestinationURL:outside)
        rejects { _=try installer.install(package,in:symlinkRoot) }
        precondition(try! fm.contentsOfDirectory(atPath:outside.path).isEmpty)
        let ancestorLink=workspace.appendingPathComponent("linked-parent",isDirectory:true)
        try fm.createSymbolicLink(at:ancestorLink,withDestinationURL:workspace)
        rejects { _=try installer.install(package,in:ancestorLink.appendingPathComponent("outside",isDirectory:true)) }
        rejects { _=try installer.install(package,in:ancestorLink.appendingPathComponent("missing-pets",isDirectory:true)) }
        precondition(!has(workspace.appendingPathComponent("missing-pets")),"Missing destination creation must validate its ancestors")
        let stagingRoot=try directory("staging-symlink")
        try fm.createSymbolicLink(at:stagingRoot.appendingPathComponent(".codex-pets-staging"),withDestinationURL:outside)
        rejects { _=try installer.install(package,in:stagingRoot) }
        let targetRoot=try directory("target-symlink")
        try fm.createSymbolicLink(at:targetRoot.appendingPathComponent(package.folderID),withDestinationURL:outside)
        rejects { _=try installer.install(package,in:targetRoot,replacingOwnedPackage:true) }
        let fileRoot=try directory("file-symlink")
        let filePackage=try installer.install(package,in:fileRoot)
        let fileIdentity=PetPackageInstaller.recordedIdentity(in:filePackage.directory)
        let originalSprite=filePackage.directory.appendingPathComponent(spriteName)
        try fm.removeItem(at:originalSprite)
        let outsideSprite=outside.appendingPathComponent("synthetic.png");try sprite.write(to:outsideSprite)
        try fm.createSymbolicLink(at:originalSprite,withDestinationURL:outsideSprite)
        precondition(PetPackageInstaller.recordedIdentity(in:filePackage.directory)==fileIdentity,"Recorded origin does not claim sprite integrity")
        precondition(try! installer.status(of:package,in:fileRoot) == .unrelated)
        rejects { _=try installer.install(package,in:fileRoot,replacingOwnedPackage:true) }
        precondition(try! Data(contentsOf:outsideSprite)==sprite)
        let danglingRoot=try directory("dangling")
        try fm.createSymbolicLink(at:danglingRoot.appendingPathComponent(package.folderID),withDestinationURL:outside.appendingPathComponent("missing"))
        rejects { _=try installer.install(package,in:danglingRoot,replacingOwnedPackage:true) }
        let invalidRoot=try directory("invalid")
        for invalid in [Data(),Data("not an image".utf8),Data(repeating:0,count:PetPackageInstaller.maximumSpriteBytes+1)] {
            var bad=package;bad.spriteData=invalid
            rejects { _=try installer.install(bad,in:invalidRoot) }
        }
        var wrongVersion=package;wrongVersion.spriteVersionNumber=1
        rejects { _=try installer.install(wrongVersion,in:invalidRoot) }
        var unknownVersion=package;unknownVersion.spriteVersionNumber=3
        rejects { _=try installer.install(unknownVersion,in:invalidRoot) }
        var pathEscape=package;pathEscape.remoteID="../escape"
        rejects { _=try installer.install(pathEscape,in:invalidRoot) }
        precondition(try! fm.contentsOfDirectory(atPath:invalidRoot.path).isEmpty,"Validation must precede any filesystem mutation")
    }
    private static func checkProcessLock(_ file:URL,shouldAcquire:Bool) throws {
        // Relaunch the synthetic test executable. Its call to run() handles the probe before
        // creating any fixture directories, then exits without unlocking the test descriptor.
        let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments=["--pet-package-lock-probe",file.path,shouldAcquire ? "acquire" : "busy"]
        child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
        try child.run();child.waitUntilExit()
        guard child.terminationReason == .exit,child.terminationStatus==0 else { throw Injected.failure }
    }
    private static func childLockProbeIfRequested() {
        let args=CommandLine.arguments
        guard args.count==4,args[1]=="--pet-package-lock-probe" else { return }
        let descriptor=Darwin.open(args[2],O_RDWR|O_NOFOLLOW|O_CLOEXEC)
        guard descriptor>=0 else { _exit(2) }
        let result=flock(descriptor,LOCK_EX|LOCK_NB),error=errno
        let success=args[3]=="acquire" ? result==0 : result != 0 && (error==EWOULDBLOCK || error==EAGAIN)
        _exit(success ? 0 : 1)
    }
}
