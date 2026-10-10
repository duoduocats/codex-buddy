import AppKit

enum PetIntegrationTests {
    @MainActor static func run(root:URL,sprite:Data) async throws {
        let preferences=PetTestPreferences()
        preferences.set(try JSONEncoder().encode(PetSource.defaults.map { var s=$0;s.enabled=false;return s }),forKey:"petStoreSources")
        let fresh=ThemeStoreModel(preferences:preferences,client:PetHTTPClient(protocolClasses:[PetFixture.self]),cacheDirectory:root.appendingPathComponent("isolation-cache"),libraryRoot:root)
        precondition(fresh.sources.allSatisfy(\.enabled) && fresh.favorites.isEmpty,"No legacy preference migration")
        var creations=0
        let controller=BuddyPetsController(factory:{ creations += 1;return fresh })
        controller.setVisible(false)
        precondition(creations == 0 && controller.store == nil,"Other main pages must not instantiate the store")
        PetFixture.reset()
        controller.setVisible(true);controller.setVisible(true)
        precondition(creations == 1 && controller.store === fresh)
        controller.setVisible(false)
        precondition(!fresh.visible && fresh.sheet == nil && !fresh.loading)

        preferences.set(try JSONEncoder().encode(PetSource.defaults.map { var s=$0;s.enabled=false;return s }),forKey:"pets.sources")
        let source=PetSource.defaults[0]
        let package=PetPackageInstaller.Package(sourceID:source.id,remoteID:"integration-pet",name:"Integration fixture",description:nil,
            author:"Synthetic Author",license:"CC0",sourceURL:source.websiteURL,imageURL:URL(string:"https://example.com/sprite.png")!,spriteVersionNumber:2,spriteData:sprite)
        let directory=root.appendingPathComponent("integration-library/pets")
        try FileManager.default.createDirectory(at:directory.deletingLastPathComponent(),withIntermediateDirectories:true)
        let receipt=try PetPackageInstaller().install(package,in:directory,replacingOwnedPackage:false)
        let marker=try JSONSerialization.jsonObject(with:Data(contentsOf:receipt.directory.appendingPathComponent("codex-pets-source.json"))) as! [String:Any]
        precondition(marker["owner"] as? String == "com.duoduocat.codexpetstore","Preserve the independent store's package marker")
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        let trash=root.appendingPathComponent("integration-trash",isDirectory:true)
        let model=ThemeStoreModel(preferences:preferences,client:PetHTTPClient(protocolClasses:[PetFixture.self]),
            cacheDirectory:root.appendingPathComponent("transaction-cache"),libraryRoot:directory.deletingLastPathComponent(),trashItem:{ url in
                entered.signal();release.wait()
                try FileManager.default.moveItem(at:url,to:trash);return trash
            })
        let coordinator=BuddyPetsController(factory:{model})
        coordinator.setVisible(true)
        for _ in 0..<200 where model.installed.isEmpty { try await Task.sleep(nanoseconds:5_000_000) }
        precondition(model.installed.count == 1,"Recognize existing compatible packages")
        model.requestUninstall(model.installed[0]);await model.finishInstallationCheck();model.confirmUninstall()
        for _ in 0..<200 {
            if hasEntered(entered) { break }
            try await Task.sleep(nanoseconds:5_000_000)
        }
        precondition(model.modifyingLocalLibrary)
        coordinator.setVisible(false)
        precondition(!model.visible && model.modifyingLocalLibrary,"Stop browsing while finishing a confirmed transaction")
        var finished=false
        let wait=Task { await coordinator.finishCurrentInstallation();finished=true }
        try await Task.sleep(nanoseconds:30_000_000)
        precondition(!finished,"Updating and quitting await the file transaction")
        release.signal();await wait.value
        precondition(!model.modifyingLocalLibrary && finished && FileManager.default.fileExists(atPath:trash.path))
        coordinator.setVisible(true)
        precondition(coordinator.store === model,"Reopening reuses the store")
        coordinator.setVisible(false)
        print("Buddy pet integration passed: lazy activation, preference isolation, package interoperability, cancellation and update/quit coordination")
    }
    private static func hasEntered(_ semaphore:DispatchSemaphore) -> Bool { semaphore.wait(timeout:.now()) == .success }
}
