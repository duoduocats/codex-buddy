import Foundation
import CryptoKit
import Darwin

struct PetPackageUninstaller {
    enum Failure:Error { case unsafePackage,changedPackage,extraFiles,trashFailed }
    struct Receipt { let originalDirectory:URL;let trashDirectory:URL? }
    var trash:(URL) throws -> URL? = { directory in
        var result:NSURL?
        try FileManager.default.trashItem(at:directory,resultingItemURL:&result)
        return result as URL?
    }
    private let fm=FileManager.default

    func validate(_ pet:InstalledPet,in root:URL,checkingExtras:Bool = true) throws -> URL {
        let parts=pet.id.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count==2,["pets","avatars"].contains(String(parts[0])),PetURL.safeComponent(String(parts[1])),
              !parts[1].hasPrefix("."),let expected=pet.manifestChecksum else { throw Failure.unsafePackage }
        let directory=root.appendingPathComponent(String(parts[0]),isDirectory:true).appendingPathComponent(String(parts[1]),isDirectory:true)
        try checkDirectories(directory)
        let filename=parts[0]=="pets" ? "pet.json" : "avatar.json"
        let data=try read(directory.appendingPathComponent(filename),maximum:65_536)
        guard Self.checksum(data)==expected,let manifest=try? JSONDecoder().decode(PetManifest.self,from:data),
              (try? manifest.validate()) != nil,manifest.version==pet.version,
              manifest.id==pet.manifestID,(manifest.displayName ?? String(parts[1]))==pet.name,
              directory.appendingPathComponent(manifest.imagePath).path==pet.imageURL.path else { throw Failure.changedPackage }
        if checkingExtras {
        let entries=try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        let allowed:Set<String>=[filename,manifest.imagePath,"codex-pets-source.json","README","README.md","README.txt","LICENSE","LICENSE.md","LICENSE.txt","ASSETS-LICENSE.md","ATTRIBUTION.md","ATTRIBUTION.txt","preview.gif","preview.png","preview.webp"]
        guard entries.allSatisfy({allowed.contains($0.lastPathComponent)}) else { throw Failure.extraFiles }
        for entry in entries {
            let attributes=try fm.attributesOfItem(atPath:entry.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.unsafePackage }
        }
        }
        let imageAttributes=try fm.attributesOfItem(atPath:pet.imageURL.path)
        let size=(imageAttributes[.size] as? NSNumber)?.intValue ?? 0
        guard size>0,size<=32_000_000 else { throw Failure.unsafePackage }
        return directory
    }
    func uninstall(_ pet:InstalledPet,in root:URL) throws -> Receipt {
        let directory=try validate(pet,in:root)
        return try PetPackageInstaller().withLibraryMutationLock(in:directory.deletingLastPathComponent()) {
            let current=try validate(pet,in:root)
            let destination=try trash(current)
            // A successful trash operation must remove the original entry; no direct deletion fallback.
            guard !fm.fileExists(atPath:current.path) else { throw Failure.trashFailed }
            return Receipt(originalDirectory:current,trashDirectory:destination)
        }
    }
    static func checksum(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private func checkDirectories(_ directory:URL) throws {
        guard directory.isFileURL,!directory.path.split(separator:"/").contains(where:{$0=="." || $0==".."}) else { throw Failure.unsafePackage }
        var current=directory
        while true {
            let attributes=try fm.attributesOfItem(atPath:current.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsafePackage }
            if current.path=="/" { break }
            current=current.deletingLastPathComponent()
        }
    }
    private func read(_ url:URL,maximum:Int) throws -> Data {
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard descriptor>=0 else { throw Failure.unsafePackage }
        defer { _=Darwin.close(descriptor) }
        var attributes=stat()
        guard fstat(descriptor,&attributes)==0,(attributes.st_mode & S_IFMT)==S_IFREG,
              attributes.st_size>0,attributes.st_size<=maximum else { throw Failure.unsafePackage }
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
        let data=try handle.read(upToCount:maximum+1) ?? Data()
        guard !data.isEmpty,data.count<=maximum else { throw Failure.unsafePackage }
        return data
    }
}
