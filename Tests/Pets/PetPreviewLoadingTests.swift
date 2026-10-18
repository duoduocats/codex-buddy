import AppKit

private actor PreviewFixtureClient:PetFetching {
    var bodies:[URL:Data]
    var delays:[URL:UInt64]
    var counts=[URL:Int]()
    init(bodies:[URL:Data],delays:[URL:UInt64] = [:]) { self.bodies=bodies;self.delays=delays }
    func data(from url:URL,limit:Int) async throws -> Data {
        counts[url,default:0] += 1
        if let delay=delays[url] { try await Task.sleep(nanoseconds:delay) }
        try Task.checkCancellation()
        guard let data=bodies[url],data.count <= limit else { throw PetStoreError.unavailable }
        return data
    }
    func count(_ url:URL) -> Int { counts[url,default:0] }
    func requestCount() -> Int { counts.values.reduce(0,+) }
    func setBody(_ data:Data?,for url:URL) { bodies[url]=data }
}

// Intentionally returns held responses even after cancellation, so a late
// transport result cannot pass by relying on URLSession cancellation alone.
private actor HeldPreviewClient:PetFetching {
    var bodies:[URL:Data]
    var blocked=Set<URL>()
    var waiting=[URL:[CheckedContinuation<Void,Never>]]()
    var counts=[URL:Int]()
    init(bodies:[URL:Data]) { self.bodies=bodies }
    func data(from url:URL,limit:Int) async throws -> Data {
        counts[url,default:0] += 1
        guard let data=bodies[url],data.count <= limit else { throw PetStoreError.unavailable }
        if blocked.contains(url) { await withCheckedContinuation { waiting[url,default:[]].append($0) } }
        return data
    }
    func hold(_ url:URL) { blocked.insert(url) }
    func release(_ url:URL) { blocked.remove(url);waiting.removeValue(forKey:url)?.forEach {$0.resume()} }
    func count(_ url:URL) -> Int { counts[url,default:0] }
    func setBody(_ data:Data,for url:URL) { bodies[url]=data }
}

@MainActor private final class HeldPreviewLaunch {
    var calls=0
    var waiters=[CheckedContinuation<Void,Never>]()
    func open(_ url:URL) async -> Result<Void,PetLaunchError> {
        calls += 1;await withCheckedContinuation { waiters.append($0) };return .success(())
    }
    func release() { let pending=waiters;waiters=[];pending.forEach {$0.resume()} }
}

enum PetPreviewLoadingTests {
    @MainActor static func run(root:URL,sprite:Data) async throws {
        let source=try PetSource.custom(url:URL(string:"https://example.com/catalog.json")!)
        var theme=try PetCatalog.decode(PetStoreTests.feed,source:source).pets[0]
        let manifest=try JSONDecoder().decode(PetManifest.self,from:PetStoreTests.manifest)
        let imageURL=try manifest.imageURL(relativeTo:theme.manifestURL)
        let licenseURL=URL(string:"https://example.com/license.txt")!
        theme.licenseURL=licenseURL;theme.previewURL=imageURL;theme.previewIsSprite=true
        let preferences=PetTestPreferences()
        preferences.set(try JSONEncoder().encode(PetSource.defaults.map { var value=$0;value.enabled=false;return value }+[source]),forKey:"pets.sources")
        let client=PreviewFixtureClient(bodies:[source.catalogURL:PetStoreTests.feed,theme.manifestURL:PetStoreTests.manifest,imageURL:sprite,licenseURL:Data("Synthetic license only".utf8)],delays:[licenseURL:250_000_000])
        let store=ThemeStoreModel(preferences:preferences,client:client,cacheDirectory:root.appendingPathComponent("preview-loading"),libraryRoot:root)
        store.open();try await PetStoreTests.wait(store)
        let thumbnail=await store.thumbnail(for:theme)
        precondition(thumbnail != nil)
        // A different visible card may finish after the card the user chooses.
        // The recent-atlas LRU must still retain the first card's exact resource.
        var otherCard=theme;otherCard.remoteID="second-card";otherCard.previewURL=URL(string:"https://example.com/second-sprite.png")!
        await client.setBody(sprite,for:otherCard.previewURL!)
        let secondThumbnail=await store.thumbnail(for:otherCard)
        precondition(secondThumbnail != nil)
        let start=Date()
        store.select(theme)
        precondition(store.selectedThumbnail === thumbnail,"Opening an already visible card should reuse its thumbnail immediately")
        for _ in 0..<100 where store.sheet == nil { try await Task.sleep(nanoseconds:5_000_000) }
        let firstSheetMS=Date().timeIntervalSince(start)*1000
        precondition(store.sheet != nil && store.preparing && store.preparedPackage == nil && store.preparedLink == nil,"Artwork should appear while the license is pending, without enabling installation")
        let spriteRequests=await client.count(imageURL)
        precondition(spriteRequests == 1,"The sprite already downloaded for the visible card should not be downloaded again")
        try await PetStoreTests.wait(store)
        precondition(store.preparedPackage?.license.contains("Synthetic license only") == true)
        let firstReadyMS=Date().timeIntervalSince(start)*1000
        let requests=await client.requestCount()
        let warmStart=Date()
        store.select(nil);store.select(theme)
        let warmMS=Date().timeIntervalSince(warmStart)*1000
        precondition(store.sheet != nil && store.preparedPackage != nil && !store.preparing)
        let warmRequests=await client.requestCount()
        precondition(warmRequests == requests,"Reopening an unchanged, recently prepared pet must not redownload its assets")
        var changed=theme;changed.inlineManifest=manifest;changed.inlineManifest?.spriteVersionNumber=1
        store.select(changed);try await PetStoreTests.wait(store)
        precondition(store.detailError != nil && store.sheet == nil && store.preparedPackage == nil,"A changed manifest version must not borrow a cached v2 preview or install payload")
        store.refresh();try await PetStoreTests.wait(store)
        await client.setBody(nil,for:licenseURL)
        store.select(theme);try await PetStoreTests.wait(store)
        precondition(store.sheet != nil && store.detailError != nil && store.preparedPackage == nil && store.preparedLink == nil,"A failed license must keep preview artwork but never enable installation")
        await client.setBody(Data("Valid license".utf8),for:licenseURL)
        store.select(theme)
        for _ in 0..<100 where store.sheet == nil { try await Task.sleep(nanoseconds:5_000_000) }
        var newest=theme;newest.remoteID="newest";newest.name="Newest pet";newest.licenseURL=nil;newest.inlineManifest=manifest;newest.inlineManifest?.displayName="Newest pet"
        store.select(newest);try await PetStoreTests.wait(store)
        try await Task.sleep(nanoseconds:280_000_000)
        precondition(store.selected?.id == newest.id && store.preparedPackage?.name == "Newest pet","A cancelled older preparation must never replace the current selection")
        store.select(theme);store.close()
        try await Task.sleep(nanoseconds:30_000_000)
        precondition(store.sheet == nil && store.selectedThumbnail == nil && store.preparedPackage == nil)

        var memory=PetPreviewMemoryCache()
        let image=try PetSprite.image(sprite,version:2)
        let package=PetPackageInstaller.Package(sourceID:theme.sourceID,remoteID:theme.remoteID,name:theme.name,description:nil,author:theme.author,license:theme.license,sourceURL:theme.websiteURL,imageURL:imageURL,spriteVersionNumber:2,spriteData:Data(repeating:0,count:20_000_000))
        let now=Date(timeIntervalSince1970:1000)
        let link=try manifest.installURL(imageURL:imageURL,fallbackName:theme.name)
        memory.insert(theme:theme,generation:1,image:image,link:link,package:package,now:now)
        memory.insert(theme:newest,generation:1,image:image,link:link,package:package,now:now)
        precondition(memory.retainedByteCount <= PetPreviewMemoryCache.maximumBytes)
        precondition(memory.detail(for:theme,generation:1,now:now) == nil,"The oldest detail must be evicted to honor the memory bound")
        precondition(memory.detail(for:newest,generation:1,now:now) != nil)
        memory.rememberSprite(sprite,url:imageURL,theme:theme,generation:1,now:now)
        precondition(memory.spriteData(url:imageURL,theme:newest,generation:1,now:now) == nil,"A shared asset URL must not cross source identities")
        precondition(memory.spriteData(url:imageURL,theme:theme,generation:2,now:now) == nil,"A refreshed catalog invalidates transient bytes")
        precondition(memory.detail(for:newest,generation:1,now:now.addingTimeInterval(121)) == nil,"Prepared package metadata must expire")
        memory.clear();precondition(memory.retainedByteCount == 0)
        let small=Data([1,2,3])
        var cards=[PetTheme]()
        for index in 0..<9 { var card=theme;card.remoteID="lru-\(index)";cards.append(card) }
        for card in cards.prefix(8) { memory.rememberSprite(small,url:imageURL,theme:card,generation:1,now:now) }
        precondition(memory.spriteData(url:imageURL,theme:cards[0],generation:1,now:now) == small)
        memory.rememberSprite(small,url:imageURL,theme:cards[8],generation:1,now:now)
        precondition(memory.spriteData(url:imageURL,theme:cards[1],generation:1,now:now) == nil,"Entry pressure must evict least recently used, not recently touched, atlases")
        precondition(memory.spriteData(url:imageURL,theme:cards[0],generation:1,now:now) == small)
        precondition(memory.spriteData(url:imageURL,theme:cards[8],generation:1,now:now.addingTimeInterval(121)) == nil)
        memory.clear()
        let large=Data(repeating:0,count:20_000_000)
        for card in cards.prefix(3) { memory.rememberSprite(large,url:imageURL,theme:card,generation:1,now:now) }
        precondition(memory.retainedByteCount <= PetPreviewMemoryCache.maximumBytes && memory.spriteData(url:imageURL,theme:cards[0],generation:1,now:now) == nil,"Bytes must evict before reaching the eight-entry count")
        memory.insert(theme:theme,generation:1,image:image,link:link,package:package,now:now)
        memory.rememberSprite(large,url:imageURL,theme:cards[4],generation:1,now:now)
        precondition(memory.retainedByteCount <= PetPreviewMemoryCache.maximumBytes && memory.detail(for:theme,generation:1,now:now) != nil,"A scrolling card must shed transient atlases before a ready detail")
        memory.clear()
        try await catalogRefreshRace(root:root,sprite:sprite,source:source,preferences:preferences)
        print(String(format:"Synthetic preview pipeline (250 ms license): first artwork %.1f ms, install-ready %.1f ms, reopen %.3f ms; one sprite transfer",firstSheetMS,firstReadyMS,warmMS))
        print("Pet preview loading passed: immediate cached thumbnail, sprite transfer reuse, license gating, exact manifest/source binding, stale selection/catalog cancellation, recent-card LRU, expiration and bounded memory")
    }
    @MainActor private static func catalogRefreshRace(root:URL,sprite:Data,source:PetSource,preferences:UserDefaults) async throws {
        let theme=try PetCatalog.decode(PetStoreTests.feed,source:source).pets[0]
        let manifest=try JSONDecoder().decode(PetManifest.self,from:PetStoreTests.manifest)
        let oldImage=try manifest.imageURL(relativeTo:theme.manifestURL)
        let client=HeldPreviewClient(bodies:[source.catalogURL:PetStoreTests.feed,theme.manifestURL:PetStoreTests.manifest,oldImage:sprite])
        let launch=HeldPreviewLaunch()
        let library=root.appendingPathComponent("preview-race-library")
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        let store=ThemeStoreModel(preferences:preferences,client:client,cacheDirectory:root.appendingPathComponent("preview-catalog-race"),libraryRoot:library,openCodexURL:{ await launch.open($0) })
        store.open();try await PetStoreTests.wait(store)
        await client.hold(theme.manifestURL)
        store.select(theme)
        for _ in 0..<100 { if await client.count(theme.manifestURL) > 0 {break};try await Task.sleep(nanoseconds:2_000_000) }
        store.refresh();try await PetStoreTests.wait(store)
        precondition(store.selected == theme && store.detailError != nil && !store.preparing,"Refreshing the same pet keeps selection and offers an explicit retry")
        await client.release(theme.manifestURL)
        try await Task.sleep(nanoseconds:20_000_000)
        precondition(store.sheet == nil && store.preparedPackage == nil && store.preparedLink == nil,"A manifest returned after the catalog generation changes cannot enable the old preview")
        store.select(store.selected);try await PetStoreTests.wait(store)
        precondition(store.sheet != nil && store.preparedPackage != nil && store.detailError == nil,"Retry after an unchanged catalog must recover normally")

        // Invalidate the ready cache, then suspend an actual image response while
        // a replacement catalog record for the same identity arrives.
        store.select(nil);store.refresh();try await PetStoreTests.wait(store)
        let initialImageCount=await client.count(oldImage)
        await client.hold(oldImage);store.select(theme)
        for _ in 0..<100 { if await client.count(oldImage) > initialImageCount {break};try await Task.sleep(nanoseconds:2_000_000) }
        let newManifestURL=URL(string:"https://example.com/pets/cat-v2/pet.json")!
        var nextManifest=manifest;nextManifest.displayName="New revision"
        let newImage=try nextManifest.imageURL(relativeTo:newManifestURL)
        let newFeed=Data(String(decoding:PetStoreTests.feed,as:UTF8.self).replacingOccurrences(of:theme.manifestURL.absoluteString,with:newManifestURL.absoluteString).replacingOccurrences(of:"Synthetic Cat",with:"New revision").utf8)
        await client.setBody(newFeed,for:source.catalogURL)
        await client.setBody(try JSONEncoder().encode(nextManifest),for:newManifestURL)
        await client.setBody(sprite,for:newImage)
        store.refresh();try await PetStoreTests.wait(store)
        precondition(store.selected?.id == theme.id && store.selected?.manifestURL == newManifestURL,"A refreshed record preserves identity while updating retry metadata")
        await client.release(oldImage);try await Task.sleep(nanoseconds:20_000_000)
        precondition(store.sheet == nil && store.preparedPackage == nil && store.preparedLink == nil)
        store.select(store.selected);try await PetStoreTests.wait(store)
        precondition(store.preparedPackage?.name == "New revision" && store.preparedPackage?.imageURL == newImage && store.detailError == nil,"Only the new catalog's validated metadata may prepare the retried pet")
        store.requestLocalInstallation();await store.finishInstallationCheck()
        precondition(store.localInstallRequest != nil)
        store.refresh()
        precondition(store.localInstallRequest == nil && store.preparedPackage == nil,"Refreshing must dismiss a consent tied to an invalidated preview")
        try await PetStoreTests.wait(store)
        store.select(store.selected);try await PetStoreTests.wait(store)
        store.requestLocalInstallation();precondition(store.checkingLocalInstall)
        store.refresh();try await PetStoreTests.wait(store)
        try await Task.sleep(nanoseconds:30_000_000)
        precondition(!store.checkingLocalInstall && store.localInstallRequest == nil,"An old installation check must not reopen consent after invalidation")
        store.select(store.selected);try await PetStoreTests.wait(store)
        store.installSelected();store.refresh();try await PetStoreTests.wait(store)
        precondition(launch.calls == 0 && !store.handingOff && !store.installationHandoff,"Cancelling a queued handoff must prevent dispatch of the old link")
        store.select(store.selected);try await PetStoreTests.wait(store)
        store.installSelected()
        for _ in 0..<100 where launch.calls == 0 { try await Task.sleep(nanoseconds:2_000_000) }
        precondition(launch.calls == 1)
        store.refresh();try await PetStoreTests.wait(store)
        launch.release();try await Task.sleep(nanoseconds:20_000_000)
        precondition(!store.handingOff && !store.installationHandoff && store.notice == nil,"A late handoff completion must not restore an old success message")
        store.close()
    }

}
