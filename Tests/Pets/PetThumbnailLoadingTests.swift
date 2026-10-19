import AppKit

private actor ThumbnailTestClient:PetFetching {
    let bytes:Data
    var active=0;var peak=0;var calls=0;var cancelled=0
    var held=true
    var continuations=[CheckedContinuation<Void,Never>]()
    init(_ bytes:Data) { self.bytes=bytes }
    func data(from url:URL,limit:Int) async throws -> Data {
        calls += 1;active += 1;peak=max(peak,active)
        defer { active -= 1 }
        // Deliberately ignores cancellation until release: physical work must
        // remain bounded, not just the number of dictionary entries.
        if held { await withCheckedContinuation { continuations.append($0) } }
        if Task.isCancelled { cancelled += 1;throw CancellationError() }
        return bytes
    }
    func release() { held=false;let pending=continuations;continuations=[];pending.forEach {$0.resume()} }
    func counts()->(Int,Int,Int) { (calls,peak,cancelled) }
}

enum PetThumbnailLoadingTests {
    @MainActor static func run(root:URL,sprite:Data) async throws {
        let source=try PetSource.custom(url:URL(string:"https://example.com/catalog.json")!)
        var theme=try PetCatalog.decode(PetStoreTests.feed,source:source).pets[0]
        theme.previewIsSprite=true
        let directory=root.appendingPathComponent("thumbnail-queue")
        let cache=PetCatalogCache(directory:directory)
        let client=ThumbnailTestClient(sprite)
        let loader=PetThumbnailLoader(client:client,cache:cache)
        var same=[Task<Void,Never>]()
        for _ in 0..<20 { let item=theme;same.append(Task { let result=await loader.image(for:item,canFetch:true);precondition(result != nil) }) }
        try await wait { await client.counts().0 == 1 }
        await client.release();for task in same { await task.value }
        let sameCount=await client.counts()
        precondition(sameCount.0 == 1,"Concurrent cells must share one transfer and decode")
        precondition(loader.cached(for:theme) != nil)
        let warm=await loader.image(for:theme,canFetch:true)
        precondition(warm?.image === loader.cached(for:theme),"A warm cell must reuse the exact decoded image")
        let warmCount=await client.counts();precondition(warmCount.0 == 1)
        let legacyName="preview-"+PetURL.key(theme.previewURL!.absoluteString+"|"+(theme.tagFingerprint ?? ""))+".png"
        try await wait { await cache.read(legacyName,limit:1_000_000) != nil }
        let restored=PetThumbnailLoader(client:client,cache:cache)
        let offline=await restored.image(for:theme,canFetch:false)
        precondition(offline != nil,"Existing disk thumbnails must restore even with fetching disabled")
        let offlineCount=await client.counts();precondition(offlineCount.0 == 1,"Disk restoration must not redownload artwork")
        loader.cancelAll();restored.cancelAll()

        let slow=ThumbnailTestClient(sprite)
        let queue=PetThumbnailLoader(client:slow,cache:PetCatalogCache(directory:root.appendingPathComponent("thumbnail-cancel")))
        var tasks=[Task<Void,Never>]()
        for i in 0..<40 {
            var item=theme;item.previewURL=URL(string:"https://example.com/queued-\(i).png")!;let pet=item
            tasks.append(Task { _=await queue.image(for:pet,canFetch:true) })
        }
        try await wait { await slow.counts().0 == PetThumbnailLoader.maximumConcurrent }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        var newest=theme;newest.previewURL=URL(string:"https://example.com/newest.png")!
        let last=newest
        let newestTask=Task { let result=await queue.image(for:last,canFetch:true);precondition(result != nil) }
        try await Task.sleep(nanoseconds:20_000_000)
        let blocked=await slow.counts();precondition(blocked.0 == PetThumbnailLoader.maximumConcurrent && blocked.1 == PetThumbnailLoader.maximumConcurrent,"Cancelled work must still occupy its slot until the transport exits")
        await slow.release();await newestTask.value
        let completed=await slow.counts();precondition(completed.0 == PetThumbnailLoader.maximumConcurrent+1 && completed.1 <= PetThumbnailLoader.maximumConcurrent && completed.2 == PetThumbnailLoader.maximumConcurrent,"Offscreen queued cells must never start; the newest visible cell gets the released slots")
        queue.cancelAll()

        let late=ThumbnailTestClient(sprite)
        let lateCache=PetCatalogCache(directory:root.appendingPathComponent("thumbnail-clear"))
        let cleared=PetThumbnailLoader(client:late,cache:lateCache)
        let old=theme
        let oldTask=Task { let result=await cleared.image(for:old,canFetch:true);precondition(result == nil) }
        try await wait { await late.counts().0 == 1 }
        cleared.cancelAll(clearImages:true);try await lateCache.clear();await late.release();await oldTask.value
        try await Task.sleep(nanoseconds:30_000_000)
        precondition(cleared.cached(for:theme) == nil,"A late result must not restore a cleared memory cache")
        let lateBytes=try await lateCache.byteCount();precondition(lateBytes == 0,"A late result must not recreate cleared files")
        let disabled=await cleared.image(for:theme,canFetch:false);precondition(disabled == nil)
        let disabledCount=await late.counts();precondition(disabledCount.0 == 1,"A disabled source must not be requested")

        // Preserve exact disk bounds while updating an existing entry and after clear.
        let bounded=PetCatalogCache(directory:root.appendingPathComponent("thumbnail-disk-bound"))
        let large=Data(repeating:1,count:200_000)
        for i in 0..<270 { try await bounded.writePreview(large,name:"preview-\(i).png") }
        let files=try FileManager.default.contentsOfDirectory(at:bounded.directory,includingPropertiesForKeys:nil)
        let size=try await bounded.byteCount()
        precondition(files.count <= 256 && size <= 32_000_000)
        try await bounded.clear();try await bounded.writePreview(Data([1]),name:"preview-after-clear.png")
        let after=try FileManager.default.contentsOfDirectory(at:bounded.directory,includingPropertiesForKeys:nil)
        precondition(after.count == 1 && after[0].lastPathComponent == "preview-after-clear.png")
        print("Thumbnail queue: duplicate coalescing, warm reuse, physical concurrency, cancellation, source and clear fences, disk bounds passed")
    }
    private static func wait(_ condition:() async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return };try await Task.sleep(nanoseconds:5_000_000) }
        preconditionFailure("Thumbnail test timed out")
    }
}
