import Foundation

enum PetPackageUninstallerTests {
    private enum Injected:Error { case failure }
    static func run(root:URL,sprite:Data) throws {
        let fm=FileManager.default
        let base=root.appendingPathComponent("uninstaller-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:base,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:base) }
        let trash=base.appendingPathComponent("synthetic-trash",isDirectory:true)
        try fm.createDirectory(at:trash,withIntermediateDirectories:false)
        var mover=PetPackageUninstaller()
        mover.trash={ url in
            let destination=trash.appendingPathComponent(UUID().uuidString,isDirectory:true)
            try fm.moveItem(at:url,to:destination);return destination
        }
        func package(_ family:String,_ slug:String) throws -> InstalledPet {
            let folder=base.appendingPathComponent(family+"/"+slug,isDirectory:true)
            try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            let manifest=PetManifest(id:slug,displayName:slug,description:"Synthetic only",spritesheetPath:"spritesheet.png",spriteVersionNumber:2)
            try JSONEncoder().encode(manifest).write(to:folder.appendingPathComponent(family=="pets" ? "pet.json" : "avatar.json"))
            try sprite.write(to:folder.appendingPathComponent("spritesheet.png"))
            return PetLocalLibrary.scan(root:base).first(where:{$0.id==family+"/"+slug})!
        }
        func rejects(_ body:() throws -> Void) {
            do { try body();preconditionFailure("Unsafe uninstall must be rejected") } catch {}
        }
        let first=try package("pets","first")
        let untouched=try package("pets","untouched")
        let firstFolder=first.imageURL.deletingLastPathComponent()
        let original=try Data(contentsOf:firstFolder.appendingPathComponent("pet.json"))
        _=try mover.validate(first,in:base)
        precondition(fm.fileExists(atPath:firstFolder.path),"Read-only confirmation must not move data")
        let receipt=try mover.uninstall(first,in:base)
        precondition(!fm.fileExists(atPath:firstFolder.path) && fm.fileExists(atPath:untouched.imageURL.path))
        precondition(try! Data(contentsOf:receipt.trashDirectory!.appendingPathComponent("pet.json"))==original)
        precondition(try! Data(contentsOf:receipt.trashDirectory!.appendingPathComponent("spritesheet.png"))==sprite)
        let legacy=try package("avatars","legacy")
        _=try mover.uninstall(legacy,in:base)
        precondition(!fm.fileExists(atPath:legacy.imageURL.path),"Legacy local avatars must support the same scoped removal")
        let failed=try package("pets","failed")
        var rejecting=PetPackageUninstaller();rejecting.trash={_ in throw Injected.failure}
        rejects { _=try rejecting.uninstall(failed,in:base) }
        precondition(fm.fileExists(atPath:failed.imageURL.path),"A failed trash request must retain the package")
        let edited=try package("pets","edited")
        try Data("modified".utf8).write(to:edited.imageURL.deletingLastPathComponent().appendingPathComponent("pet.json"))
        rejects { _=try mover.uninstall(edited,in:base) }
        let extras=try package("pets","extras")
        let extra=extras.imageURL.deletingLastPathComponent().appendingPathComponent("personal.txt")
        try Data("Synthetic personal data".utf8).write(to:extra)
        rejects { _=try mover.uninstall(extras,in:base) }
        precondition(fm.fileExists(atPath:extra.path))
        _=try mover.validate(extras,in:base,checkingExtras:false)
        let linked=try package("pets","linked")
        try fm.removeItem(at:linked.imageURL)
        try fm.createSymbolicLink(at:linked.imageURL,withDestinationURL:untouched.imageURL)
        rejects { _=try mover.uninstall(linked,in:base) }
        precondition(fm.fileExists(atPath:untouched.imageURL.path))
        var escape=untouched;escape.id="pets/../escape"
        rejects { _=try mover.uninstall(escape,in:base) }
        var forged=untouched;forged.imageURL=first.imageURL
        rejects { _=try mover.uninstall(forged,in:base) }
        print("Pet uninstall passed: scoped pets/avatars, confirmation without mutation, retained Trash bytes, failure preservation, changed metadata, unrelated files, symlinks and path escape")
    }
}
