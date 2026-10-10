import Foundation
import AppKit
import CryptoKit
import Darwin

// Prepared fallback only. The caller must explicitly obtain approval and supply the pets directory.
// This type never resolves CODEX_HOME, changes the selected pet, or opens Codex.
struct PetPackageInstaller {
    struct Package {
        var sourceID:String
        var remoteID:String
        var name:String
        var description:String?
        var author:String
        var license:String
        var sourceURL:URL
        var imageURL:URL
        var spriteVersionNumber:Int
        var spriteData:Data
        var folderID:String { PetPackageInstaller.folderID(sourceID:sourceID,remoteID:remoteID) }
    }
    struct Receipt {
        let directory:URL
        let backupDirectory:URL?
    }
    enum Status:Equatable { case absent, current, update, unrelated }
    struct RecordedIdentity:Equatable {
        let sourceID:String
        let remoteID:String
    }
    enum Checkpoint:CaseIterable {
        case staged, beforeBackup, afterBackup, beforeCommit, afterCommit
    }
    enum Failure:Error {
        case invalidPackage, unsafePath, unrelatedCollision, replacementNotApproved, busy
        case rollbackFailed(backup:URL?, displaced:URL?)
    }
    private struct Manifest:Codable {
        let id:String
        let displayName:String
        let description:String?
        let spriteVersionNumber:Int
        let spritesheetPath:String
    }
    private struct SourceRecord:Codable {
        let schemaVersion:Int
        let owner:String
        let sourceID:String
        let remoteID:String
        let author:String
        let license:String
        let sourceURL:URL
        let imageURL:URL
        let manifestSHA256:String
        let spriteSHA256:String
    }
    static let maximumSpriteBytes=20*1024*1024
    private static let owner="com.duoduocat.codexpetstore"
    private static let sourceFilename="codex-pets-source.json"
    private static let lockFilename=".install.lock"
    var checkpoint:(Checkpoint) throws -> Void = { _ in }
    private let fm=FileManager.default

    static func folderID(sourceID:String,remoteID:String) -> String {
        // Length-prefixed fields prevent ambiguous source/remote combinations.
        let identity="\(sourceID.utf8.count):\(sourceID)\(remoteID.utf8.count):\(remoteID)"
        return "codex-pets-"+digest(Data(identity.utf8))
    }
    // Read-only origin lookup for routine scans. It checks the bounded marker and manifest hash,
    // but deliberately does not read/hash the sprite and does not claim complete package integrity.
    static func recordedIdentity(in directory:URL) -> RecordedIdentity? {
        let installer=PetPackageInstaller()
        guard let metadata=try? installer.readMetadata(directory),
              directory.lastPathComponent==folderID(sourceID:metadata.record.sourceID,remoteID:metadata.record.remoteID) else { return nil }
        return RecordedIdentity(sourceID:metadata.record.sourceID,remoteID:metadata.record.remoteID)
    }
    // Coordinate a confirmed removal with other store installation transactions.
    func withLibraryMutationLock<T>(in directory:URL,operation:() throws -> T) throws -> T {
        try checkedDirectory(directory)
        let staging=directory.appendingPathComponent(".codex-pets-staging",isDirectory:true)
        try ensurePrivateDirectory(staging)
        guard let lock=try acquireLock(in:staging,creating:true,exclusive:true) else { throw Failure.unsafePath }
        defer { lock.release() }
        return try operation()
    }
    // Full selected-package verification. This never creates directories or resolves a Codex home.
    // Run off the main thread; the sprite hash can read up to 20 MiB. A concurrent installer throws busy.
    func status(of package:Package,in destinationDirectory:URL) throws -> Status {
        let prepared=try prepare(package)
        try checkPath(destinationDirectory)
        guard try exists(destinationDirectory) else {
            try checkedDirectory(destinationDirectory.deletingLastPathComponent())
            return .absent
        }
        try checkedDirectory(destinationDirectory)
        let staging=destinationDirectory.appendingPathComponent(".codex-pets-staging",isDirectory:true)
        var lock:DirectoryLock?
        if try exists(staging) {
            try checkedDirectory(staging)
            lock=try acquireLock(in:staging,creating:false,exclusive:false)
        }
        defer { lock?.release() }
        let target=destinationDirectory.appendingPathComponent(package.folderID,isDirectory:true)
        guard try exists(target) else { return .absent }
        do { try checkOwned(target,package:package) } catch { return .unrelated }
        let source=try boundedData(target.appendingPathComponent(Self.sourceFilename),maximum:65_536)
        return source==prepared.source ? .current : .update
    }

    func install(_ package:Package,in destinationDirectory:URL,replacingOwnedPackage:Bool = false) throws -> Receipt {
        let prepared=try prepare(package)
        let destination=try ensureDestinationDirectory(destinationDirectory)
        let target=destination.appendingPathComponent(package.folderID,isDirectory:true)
        let staging=destination.appendingPathComponent(".codex-pets-staging",isDirectory:true)
        try ensurePrivateDirectory(staging)
        guard let lock=try acquireLock(in:staging,creating:true,exclusive:true) else { throw Failure.unsafePath }
        defer { lock.release() }
        if try exists(target) {
            try checkOwned(target,package:package)
            guard replacingOwnedPackage else { throw Failure.replacementNotApproved }
        }
        let transaction=staging.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:transaction,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let pending=transaction.appendingPathComponent("pending",isDirectory:true)
        try fm.createDirectory(at:pending,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var backup:URL?
        var committed=false
        do {
            try prepared.manifest.write(to:pending.appendingPathComponent("pet.json"),options:.atomic)
            try package.spriteData.write(to:pending.appendingPathComponent(prepared.spriteFilename),options:.atomic)
            try prepared.source.write(to:pending.appendingPathComponent(Self.sourceFilename),options:.atomic)
            try checkOwned(pending,package:package)
            try checkpoint(.staged)
            try checkedDirectory(destination)
            try checkedDirectory(staging)
            try checkedDirectory(transaction)
            guard try sameFilesystem(destination,transaction) else { throw Failure.unsafePath }
            try checkpoint(.beforeBackup)
            // Recheck after staging and immediately before mutation; never overwrite a new collision.
            if try exists(target) {
                try checkOwned(target,package:package)
                guard replacingOwnedPackage else { throw Failure.replacementNotApproved }
                let prior=transaction.appendingPathComponent("previous",isDirectory:true)
                try fm.moveItem(at:target,to:prior)
                backup=prior
            }
            try checkpoint(.afterBackup)
            try checkpoint(.beforeCommit)
            try checkedDirectory(destination)
            try checkedDirectory(transaction)
            guard try sameFilesystem(destination,pending) else { throw Failure.unsafePath }
            try checkOwned(pending,package:package)
            guard try !exists(target) else { throw Failure.unrelatedCollision }
            // Source and destination share a parent filesystem. moveItem commits the complete directory.
            try fm.moveItem(at:pending,to:target)
            committed=true
            try checkpoint(.afterCommit)
            if backup == nil { try? fm.removeItem(at:transaction) }
            return Receipt(directory:target,backupDirectory:backup)
        } catch {
            let original=error
            var displaced:URL?
            do {
                try checkedDirectory(destination)
                try checkedDirectory(staging)
                try checkedDirectory(transaction)
                if committed {
                    // Retain the failed new package too; avoid deleting data during rollback.
                    try checkOwned(target,package:package)
                    let failed=transaction.appendingPathComponent("failed-new",isDirectory:true)
                    try fm.moveItem(at:target,to:failed)
                    displaced=failed
                }
                if let backup {
                    guard try !exists(target) else { throw Failure.unrelatedCollision }
                    try checkOwned(backup,package:package)
                    try fm.moveItem(at:backup,to:target)
                }
                // Pending files are newly staged by this call and are safe to remove after validation.
                // If a disk write failed before staging completed, keep the incomplete hidden
                // transaction. Nothing outside it has changed; its failure must not mask rollback.
                if try exists(pending), (try? checkOwned(pending,package:package)) != nil {
                    try fm.removeItem(at:pending)
                }
                if displaced == nil, (try? fm.contentsOfDirectory(atPath:transaction.path).isEmpty)==true {
                    try? fm.removeItem(at:transaction)
                }
            } catch {
                throw Failure.rollbackFailed(backup:backup,displaced:displaced)
            }
            throw original
        }
    }

    private func prepare(_ package:Package) throws -> (manifest:Data,source:Data,spriteFilename:String) {
        let name=package.name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=160,name.utf8.count<=8_000,
              !package.sourceID.isEmpty,package.sourceID.utf8.count<=512,
              PetURL.safeComponent(package.remoteID),
              !package.sourceID.contains("\0"),!package.remoteID.contains("\0"),
              (package.description?.count ?? 0)<=2000,(package.description?.utf8.count ?? 0)<=16_000,
              !package.author.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !package.license.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              package.author.utf8.count<=4096,package.license.utf8.count<=48_000,
              [1,2].contains(package.spriteVersionNumber),
              !package.spriteData.isEmpty,package.spriteData.count<=Self.maximumSpriteBytes else { throw Failure.invalidPackage }
        _=try PetURL.validate(package.sourceURL)
        _=try PetURL.validate(package.imageURL)
        let bytes=[UInt8](package.spriteData.prefix(12))
        let suffix:String
        if bytes.starts(with:[137,80,78,71,13,10,26,10]) { suffix="png" }
        else if bytes.count>=12,String(bytes:bytes[0..<4],encoding:.ascii)=="RIFF",String(bytes:bytes[8..<12],encoding:.ascii)=="WEBP" { suffix="webp" }
        else { throw Failure.invalidPackage }
        guard let dimensions=Self.dimensions(package.spriteData,suffix:suffix),dimensions.width==1536,
              dimensions.height==(package.spriteVersionNumber==1 ? 1872 : 2288),
              let image=NSBitmapImageRep(data:package.spriteData),image.pixelsWide==1536,
              image.pixelsHigh==(package.spriteVersionNumber==1 ? 1872 : 2288) else { throw Failure.invalidPackage }
        let filename="spritesheet."+suffix
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        let manifest=try encoder.encode(Manifest(id:package.remoteID,displayName:name,
            description:package.description,spriteVersionNumber:package.spriteVersionNumber,spritesheetPath:filename))
        let source=try encoder.encode(SourceRecord(schemaVersion:1,owner:Self.owner,
            sourceID:package.sourceID,remoteID:package.remoteID,author:package.author,license:package.license,
            sourceURL:package.sourceURL,imageURL:package.imageURL,
            manifestSHA256:Self.digest(manifest),spriteSHA256:Self.digest(package.spriteData)))
        guard manifest.count<=65_536,source.count<=65_536 else { throw Failure.invalidPackage }
        return (manifest,source,filename)
    }

    private func checkOwned(_ directory:URL,package:Package) throws {
        let metadata=try readMetadata(directory)
        let entries=try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        let record=metadata.record,manifest=metadata.manifest
        guard record.sourceID==package.sourceID,record.remoteID==package.remoteID,
              entries.count==3,Set(entries.map(\.lastPathComponent))==Set(["pet.json",Self.sourceFilename,manifest.spritesheetPath]) else { throw Failure.unrelatedCollision }
        let spriteURL=directory.appendingPathComponent(manifest.spritesheetPath)
        guard try regularFile(spriteURL,maximum:Self.maximumSpriteBytes),
              Self.digest(try boundedData(spriteURL,maximum:Self.maximumSpriteBytes))==record.spriteSHA256 else { throw Failure.unrelatedCollision }
    }
    private func readMetadata(_ directory:URL) throws -> (record:SourceRecord,manifest:Manifest) {
        try checkedDirectory(directory)
        let manifestURL=directory.appendingPathComponent("pet.json"),recordURL=directory.appendingPathComponent(Self.sourceFilename)
        guard try regularFile(recordURL,maximum:65_536),try regularFile(manifestURL,maximum:65_536),
              let record=try? JSONDecoder().decode(SourceRecord.self,from:boundedData(recordURL,maximum:65_536)),
              record.schemaVersion==1,record.owner==Self.owner,!record.sourceID.isEmpty,record.sourceID.utf8.count<=512,
              PetURL.safeComponent(record.remoteID),
              let manifestData=try? boundedData(manifestURL,maximum:65_536),
              let manifest=try? JSONDecoder().decode(Manifest.self,from:manifestData),
              manifest.id==record.remoteID,[1,2].contains(manifest.spriteVersionNumber),
              !manifest.displayName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              ["spritesheet.png","spritesheet.webp"].contains(manifest.spritesheetPath),
              Self.digest(manifestData)==record.manifestSHA256 else { throw Failure.unrelatedCollision }
        return (record,manifest)
    }
    private final class DirectoryLock {
        private var descriptor:Int32
        init(_ descriptor:Int32) { self.descriptor=descriptor }
        func release() {
            if descriptor>=0 { _=flock(descriptor,LOCK_UN);_ = Darwin.close(descriptor);descriptor = -1 }
        }
        deinit { release() }
    }
    private func acquireLock(in staging:URL,creating:Bool,exclusive:Bool) throws -> DirectoryLock? {
        try checkedDirectory(staging)
        let url=staging.appendingPathComponent(Self.lockFilename)
        let flags=(creating ? O_RDWR|O_CREAT : O_RDONLY)|O_NOFOLLOW|O_CLOEXEC
        let descriptor=Darwin.open(url.path,flags,0o600)
        guard descriptor>=0 else {
            if !creating && errno==ENOENT { return nil }
            throw Failure.unsafePath
        }
        var attributes=stat()
        guard fstat(descriptor,&attributes)==0,(attributes.st_mode & S_IFMT)==S_IFREG,attributes.st_nlink==1 else {
            _=Darwin.close(descriptor);throw Failure.unsafePath
        }
        guard flock(descriptor,(exclusive ? LOCK_EX : LOCK_SH)|LOCK_NB)==0 else {
            let error=errno;_ = Darwin.close(descriptor)
            if error==EWOULDBLOCK || error==EAGAIN { throw Failure.busy }
            throw Failure.unsafePath
        }
        return DirectoryLock(descriptor)
    }
    @discardableResult private func checkedDirectory(_ url:URL) throws -> URL {
        try checkPath(url)
        var current=url
        while true {
            let values=try fm.attributesOfItem(atPath:current.path)
            guard values[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsafePath }
            if current.path=="/" { break }
            let parent=current.deletingLastPathComponent()
            if parent.path==current.path { break }
            current=parent
        }
        return url
    }
    private func checkPath(_ url:URL) throws {
        guard url.isFileURL,url.host==nil || url.host=="" || url.host=="localhost" else { throw Failure.unsafePath }
        // standardizedFileURL rewrites /private/tmp to the /tmp symlink on macOS.
        // Validate lexical components directly so ancestor checks see the supplied real path.
        guard url.path.hasPrefix("/"),!url.path.split(separator:"/").contains(where: { $0=="." || $0==".." }) else { throw Failure.unsafePath }
    }
    private func ensureDestinationDirectory(_ url:URL) throws -> URL {
        try checkPath(url)
        if try !exists(url) {
            // Only create the explicit destination, after validating its existing parent chain.
            // The caller must supply an existing Codex home/parent rather than asking us to create one.
            try checkedDirectory(url.deletingLastPathComponent())
            try fm.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        }
        return try checkedDirectory(url)
    }
    private func ensurePrivateDirectory(_ url:URL) throws {
        if try !exists(url) { try fm.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]) }
        try checkedDirectory(url)
        // A staging directory with a root manifest would be discoverable by Codex; refuse it.
        guard try !exists(url.appendingPathComponent("pet.json")),try !exists(url.appendingPathComponent("avatar.json")) else { throw Failure.unsafePath }
    }
    private func regularFile(_ url:URL,maximum:Int) throws -> Bool {
        guard let values=try attributesIfPresent(url) else { return false }
        let size=(values[.size] as? NSNumber)?.intValue ?? Int.max
        return values[.type] as? FileAttributeType == .typeRegular && size>0 && size<=maximum
    }
    private func boundedData(_ url:URL,maximum:Int) throws -> Data {
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard descriptor>=0 else { throw Failure.unrelatedCollision }
        defer { _=Darwin.close(descriptor) }
        var attributes=stat()
        guard fstat(descriptor,&attributes)==0,(attributes.st_mode & S_IFMT)==S_IFREG,
              attributes.st_size>0,attributes.st_size<=maximum else { throw Failure.unrelatedCollision }
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
        var result=Data()
        while result.count<=maximum {
            guard let bytes=try handle.read(upToCount:min(65_536,maximum+1-result.count)),!bytes.isEmpty else { break }
            result.append(bytes)
        }
        guard !result.isEmpty,result.count<=maximum else { throw Failure.unrelatedCollision }
        return result
    }
    private func attributesIfPresent(_ url:URL) throws -> [FileAttributeKey:Any]? {
        do { return try fm.attributesOfItem(atPath:url.path) }
        catch let error as NSError where error.domain==NSCocoaErrorDomain && error.code==NSFileReadNoSuchFileError { return nil }
    }
    private func exists(_ url:URL) throws -> Bool { try attributesIfPresent(url) != nil }
    private func sameFilesystem(_ first:URL,_ second:URL) throws -> Bool {
        let a=try fm.attributesOfItem(atPath:first.path)[.systemNumber] as? NSNumber
        let b=try fm.attributesOfItem(atPath:second.path)[.systemNumber] as? NSNumber
        return a != nil && a==b
    }
    private static func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func dimensions(_ data:Data,suffix:String) -> (width:Int,height:Int)? {
        // Check declared dimensions before decoding to avoid allocating an oversized bitmap.
        let bytes=[UInt8](data)
        func little(_ offset:Int,_ count:Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(bytes[offset+$1]) << (8*$1) }
        }
        if suffix=="png" {
            guard bytes.count>=24,Array(bytes[12..<16])==Array("IHDR".utf8) else { return nil }
            func big(_ offset:Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset+$1]) } }
            return (big(16),big(20))
        }
        guard bytes.count>=20,little(4,4)==bytes.count-8 else { return nil }
        var offset=12
        while offset+8<=bytes.count {
            let chunk=String(bytes:bytes[offset..<offset+4],encoding:.ascii)
            let length=little(offset+4,4),start=offset+8
            guard length<=bytes.count-start else { return nil }
            if chunk=="VP8X",length>=10 { return (little(start+4,3)+1,little(start+7,3)+1) }
            if chunk=="VP8L",length>=5,bytes[start]==47 {
                let bits=little(start+1,4)
                return (bits%16384+1,(bits/16384)%16384+1)
            }
            if chunk=="VP8 ",length>=10,Array(bytes[start+3..<start+6])==[157,1,42] {
                return (little(start+6,2)%16384,little(start+8,2)%16384)
            }
            offset=start+length+length%2
        }
        return nil
    }
}
