import AppKit
import ImageIO

// One queue for the grid, not one unbounded download/decode task per cell.
// AppKit images stay on the main actor; ImageIO and file work run in workers.
@MainActor final class PetThumbnailLoader {
    struct Loaded {
        let image:NSImage
        let sprite:Data?
    }
    private struct Job {
        let id:UUID
        let theme:PetTheme
        let canFetch:Bool
        var waiters:[UUID:CheckedContinuation<Loaded?,Never>]
    }
    static let maximumConcurrent=8
    private let client:PetFetching
    private let cache:PetCatalogCache
    private let images=NSCache<NSString,NSImage>()
    private let decoders=[PetThumbnailDecoder(),PetThumbnailDecoder()]
    private var nextDecoder=0
    private var jobs=[String:Job]()
    private var queue=[String]()
    private var workers=[UUID:Task<Void,Never>]()

    init(client:PetFetching,cache:PetCatalogCache) {
        self.client=client;self.cache=cache
        images.countLimit=256;images.totalCostLimit=32_000_000
    }
    static func key(for theme:PetTheme)->String? {
        theme.previewURL.map { $0.absoluteString+"|"+(theme.tagFingerprint ?? "") }
    }
    func cached(for theme:PetTheme)->NSImage? {
        guard let key=Self.key(for:theme) else { return nil }
        return images.object(forKey:key as NSString)
    }
    func image(for theme:PetTheme,canFetch:Bool) async -> Loaded? {
        guard !Task.isCancelled,let key=Self.key(for:theme) else { return nil }
        if let image=images.object(forKey:key as NSString) { return Loaded(image:image,sprite:nil) }
        let waiter=UUID()
        return await withTaskCancellationHandler(operation:{
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning:nil);return }
                if var job=jobs[key] {
                    job.waiters[waiter]=continuation;jobs[key]=job
                } else {
                    jobs[key]=Job(id:UUID(),theme:theme,canFetch:canFetch,waiters:[waiter:continuation])
                    queue.append(key)
                }
                startNext()
            }
        },onCancel:{ Task { @MainActor [weak self] in self?.cancel(waiter,key:key) } })
    }
    func cancelAll(clearImages:Bool = false) {
        let pending=jobs.values; jobs=[:];queue=[]
        for job in pending { for waiter in job.waiters.values { waiter.resume(returning:nil) } }
        // Keep occupied slots until even a cancellation-ignoring transport exits.
        for worker in workers.values { worker.cancel() }
        if clearImages { images.removeAllObjects() }
    }
    private func cancel(_ waiter:UUID,key:String) {
        guard var job=jobs[key],let continuation=job.waiters.removeValue(forKey:waiter) else { return }
        continuation.resume(returning:nil)
        if job.waiters.isEmpty {
            jobs.removeValue(forKey:key);queue.removeAll {$0 == key};workers[job.id]?.cancel()
        } else { jobs[key]=job }
    }
    private func startNext() {
        while workers.count < Self.maximumConcurrent,!queue.isEmpty {
            let key=queue.removeFirst()
            guard let job=jobs[key],let url=job.theme.previewURL else { continue }
            let id=job.id;let sprite=job.theme.previewIsSprite;let allowed=job.canFetch
            let client=client;let cache=cache;let decoder=decoders[nextDecoder]
            nextDecoder=(nextDecoder+1)%decoders.count
            workers[id]=Task.detached(priority:.userInitiated) { [weak self] in
                do {
                    try Task.checkCancellation()
                    let frame:CGImage;var downloaded:Data?
                    let name="preview-"+PetURL.key(key)+".png"
                    if let bytes=await cache.read(name,limit:1_000_000),
                       let cached=try? await decoder.image(bytes,sprite:false) { frame=cached }
                    else {
                        guard allowed else { throw PetStoreError.unavailable }
                        let bytes=try await client.data(from:url,limit:sprite ? 32_000_000 : 6_000_000,kind:.preview)
                        try Task.checkCancellation()
                        frame=try await decoder.image(bytes,sprite:sprite)
                        downloaded=bytes
                    }
                    try Task.checkCancellation()
                    let delivered=await self?.deliver(frame,sprite:sprite ? downloaded:nil,key:key,id:id) ?? false
                    // Display first. Encoding, atomic writes and eviction must not
                    // hold the cell's result hostage. Still bounded by the worker limit.
                    if delivered,downloaded != nil {
                        try Task.checkCancellation()
                        let png:Data?=autoreleasepool {
                            let bytes=NSMutableData()
                            guard let writer=CGImageDestinationCreateWithData(bytes,"public.png" as CFString,1,nil) else { return nil }
                            CGImageDestinationAddImage(writer,frame,nil)
                            return CGImageDestinationFinalize(writer) ? bytes as Data:nil
                        }
                        if let png { try Task.checkCancellation();try await cache.writePreview(png,name:name) }
                    }
                } catch { await self?.fail(key:key,id:id) }
                await self?.finished(id)
            }
        }
    }
    private func deliver(_ frame:CGImage,sprite:Data?,key:String,id:UUID)->Bool {
        guard let job=jobs[key],job.id == id else { return false }
        jobs.removeValue(forKey:key)
        let image=NSImage(cgImage:frame,size:NSSize(width:frame.width,height:frame.height))
        images.setObject(image,forKey:key as NSString,cost:frame.bytesPerRow*frame.height)
        let result=Loaded(image:image,sprite:sprite)
        for waiter in job.waiters.values { waiter.resume(returning:result) }
        return true
    }
    private func fail(key:String,id:UUID) {
        guard let job=jobs[key],job.id == id else { return }
        jobs.removeValue(forKey:key)
        for waiter in job.waiters.values { waiter.resume(returning:nil) }
    }
    private func finished(_ id:UUID) { workers.removeValue(forKey:id);startNext() }
}

// Downloads can overlap network latency without decoding many full sprite
// atlases at once. Each of the two actors serializes CPU work off the UI actor.
private actor PetThumbnailDecoder {
    func image(_ bytes:Data,sprite:Bool) throws -> CGImage {
        try Task.checkCancellation()
        return try autoreleasepool { try PetSprite.thumbnailImage(bytes,sprite:sprite) }
    }
}
