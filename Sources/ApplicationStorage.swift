import Foundation
import Combine

struct ApplicationStorageSnapshot: Equatable {
    var applicationBytes: Int64
    var dataBytes: Int64
    var cacheBytes: Int64
    var forecastBytes: Int64 = 0
    var tagBytes: Int64 = 0
    var totalBytes: Int64 { applicationBytes+dataBytes+cacheBytes+forecastBytes+tagBytes }
}
struct ApplicationStorage {
    let application: URL
    let preferencesFile: URL
    let cache: PetCatalogCache
    let tagStore:PetTagStore?
    let forecastCache: UsageForecastCache?
    let forecastEvaluationStore: UsageForecastEvaluationStore?
    init(application: URL = Bundle.main.bundleURL,preferencesFile: URL? = nil,cache: PetCatalogCache = .shared,
         forecastCache: UsageForecastCache? = nil,forecastEvaluationStore: UsageForecastEvaluationStore? = nil,tagStore:PetTagStore? = nil) {
        self.application=application;self.cache=cache;self.forecastCache=forecastCache
        self.forecastEvaluationStore=forecastEvaluationStore;self.tagStore=tagStore
        self.preferencesFile=preferencesFile ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.duoduocat.codexbuddy.plist")
    }
    static func filesSize(_ directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]
        guard (try? directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true,
              let files=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:Array(keys),options:[]) else { return 0 }
        var bytes: Int64=0
        for case let file as URL in files {
            guard let values=try? file.resourceValues(forKeys:keys) else { continue }
            if values.isSymbolicLink == true { files.skipDescendants();continue }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }
    func snapshot() async throws -> ApplicationStorageSnapshot {
        let application=application,preferencesFile=preferencesFile
        let saved=await Task.detached(priority:.utility) {
            let values=try? FileManager.default.attributesOfItem(atPath:preferencesFile.path)
            let linked=values?[.type] as? FileAttributeType == .typeSymbolicLink
            return (Self.filesSize(application),linked ? Int64(0) : (values?[.size] as? NSNumber)?.int64Value ?? 0)
        }.value
        return .init(applicationBytes:saved.0,dataBytes:saved.1,cacheBytes:try await cache.byteCount(),
                     // These actors share a parent folder but own distinct
                     // leaves. Count each leaf once, without a second parent scan.
                     forecastBytes:(try await forecastCache?.byteCount() ?? 0)
                        + (try await forecastEvaluationStore?.byteCount() ?? 0),tagBytes:try await tagStore?.cache.byteCount() ?? 0)
    }
}

@MainActor final class ApplicationStorageModel: ObservableObject {
    @Published private(set) var snapshot: ApplicationStorageSnapshot?
    @Published private(set) var loading=false
    @Published private(set) var clearing=false
    @Published private(set) var message: String?
    private let storage: ApplicationStorage
    private var task: Task<Void,Never>?
    private var generation=0
    init(storage: ApplicationStorage? = nil) { self.storage=storage ?? .init(forecastCache:.shared,forecastEvaluationStore:.shared,tagStore:.shared) }
    func refresh() {
        guard !loading,!clearing else { return }
        generation += 1;let ticket=generation;loading=true
        task=Task {
            defer { if ticket == generation { loading=false;task=nil } }
            do {
                let result=try await storage.snapshot()
                guard !Task.isCancelled,ticket == generation else { return }
                if snapshot != result { snapshot=result }
            } catch { if ticket == generation { message=L("暂时无法读取数据大小。", "Could not read data sizes.") } }
        }
    }
    func clear(using pets: BuddyPetsController,includingUsageHistory:Bool = false) {
        guard !clearing,!pets.modifyingLocalLibrary else { return }
        task?.cancel();generation += 1;let ticket=generation;loading=false;clearing=true;message=nil
        task=Task {
            defer { if ticket == generation { clearing=false;task=nil } }
            do {
                // Invalidate evaluation sessions first; a quota RPC already in
                // flight cannot recreate predictions after the history is gone.
                if includingUsageHistory {
                    try await storage.forecastEvaluationStore?.clear()
                    try await storage.forecastCache?.clear()
                    NotificationCenter.default.post(name:.buddyUsageForecastCacheCleared,object:nil)
                }
                try await storage.tagStore?.clear()
                try await pets.clearCache()
                snapshot=try await storage.snapshot()
                message=L("缓存已清理。", "Cache cleared.")
            } catch { message=L("缓存未能完全清理，请重试。", "Could not clear all cached data. Try again.") }
        }
    }
    func finish() async { await task?.value }
}
