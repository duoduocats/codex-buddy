import Foundation
import AppKit

private final class StorageTestPreferences: UserDefaults {
    private var values=[String:Any]()
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?,forKey key: String) { values[key]=value }
}
private struct StorageNoNetworkClient: PetFetching {
    func data(from url: URL,limit: Int) async throws -> Data {
        preconditionFailure("Storage tests must not fetch a remote catalog")
    }
}

@main struct ApplicationStorageTests {
    static let key=String(repeating:"a",count:64)
    static func check(_ condition: Bool,_ message: String = "Storage regression",line: Int = #line) {
        if !condition { fatalError("\(message) at line \(line)") }
    }
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/buddy-forecast-storage-tests-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let app=root.appendingPathComponent("Synthetic.app"),prefs=root.appendingPathComponent("synthetic-settings.plist")
        try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true)
        try Data(repeating:1,count:100).write(to:app.appendingPathComponent("binary"))
        let saved=Data("synthetic preserved settings and messages".utf8);try saved.write(to:prefs)
        let installed=root.appendingPathComponent("synthetic-installed-pet.png");try saved.write(to:installed)
        let now=Date(),reset=now.addingTimeInterval(18 * 3_600)
        let bucket=LimitBucket(limitId:"codex",limitName:nil,primary:
            .init(usedPercent:50,windowDurationMins:10_080,resetsAt:reset.timeIntervalSince1970),secondary:nil,planType:"plus")
        let usage=UsageResponse(rateLimits:bucket,rateLimitsByLimitId:nil,rateLimitResetCredits:nil)
        var notifications=0
        let observer=NotificationCenter.default.addObserver(forName:.buddyUsageForecastCacheCleared,object:nil,queue:nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        func fixture(_ name: String) async throws -> (ApplicationStorage, BuddyPetsController, UsageForecastEvaluationSession) {
            let directory=root.appendingPathComponent(name,isDirectory:true)
            let petsDirectory=directory.appendingPathComponent("Pets",isDirectory:true)
            let petsCache=PetCatalogCache(directory:petsDirectory)
            try await petsCache.write(Data(repeating:2,count:321),name:"catalog.json")
            let forecastDirectory=directory.appendingPathComponent("UsageForecast",isDirectory:true)
            let history=UsageForecastCache(directory:forecastDirectory)
            let evaluation=UsageForecastEvaluationStore(directory:forecastDirectory)
            let observations=try await history.record(usage:usage,accountKey:key,at:now)
            let session=await evaluation.session(accountKey:key,accountGeneration:1)!
            let prediction=UsageForecastIssuedPrediction(windowID:.init(bucketID:"codex",role:.primary),issuedAt:now,
                inputCutoff:now,modelVersion:"synthetic-linear-v1",windowResetEpoch:reset,
                predictedExhaustionAt:now.addingTimeInterval(10 * 3_600),rate:5,remaining:50,
                windowDurationMins:10_080,planType:"plus",source:"native-wham",segmentID:observations.last?.segmentID)
            _ = try await evaluation.record(prediction,session:session,at:now)
            let preferences=StorageTestPreferences()
            let store=ThemeStoreModel(preferences:preferences,client:StorageNoNetworkClient(),cacheDirectory:petsDirectory,
                libraryRoot:root,openURL:{_ in false},openCodexURL:{_ in .success(())},trashItem:{_ in nil},copyText:{_ in false})
            store.usePreview(themes:[])
            let controller=BuddyPetsController(factory:{store});controller.setVisible(true);controller.setVisible(false)
            return (.init(application:app,preferencesFile:prefs,cache:petsCache,forecastCache:history,
                forecastEvaluationStore:evaluation),controller,session)
        }

        let (preserved,preservedController,preservedSession)=try await fixture("preserved-history")
        let preservedBytes=try await preserved.snapshot().forecastBytes
        let cacheOnly=ApplicationStorageModel(storage:preserved)
        cacheOnly.clear(using:preservedController);await cacheOnly.finish()
        check(cacheOnly.snapshot?.forecastBytes == preservedBytes && cacheOnly.snapshot?.cacheBytes == 0 && notifications == 0,"Ordinary cache cleanup retains quota history and evaluations")
        check(try await preserved.forecastEvaluationStore!.records(session:preservedSession,at:now).count > 0)
        let (policy,controller,oldSession)=try await fixture("success")
        let historyBytes=try await policy.forecastCache!.byteCount()
        let evaluationBytes=try await policy.forecastEvaluationStore!.byteCount()
        let before=try await policy.snapshot()
        check(historyBytes > 0 && evaluationBytes > 0 && before.forecastBytes == historyBytes + evaluationBytes,
                     "Shared forecast parent leaves must each count exactly once")
        check(before.totalBytes == 100 + Int64(saved.count) + 321 + historyBytes + evaluationBytes)
        let storage=ApplicationStorageModel(storage:policy)
        storage.clear(using:controller,includingUsageHistory:true);await storage.finish()
        check(storage.snapshot?.forecastBytes == 0 && storage.snapshot?.cacheBytes == 0 && !storage.clearing
            && storage.message == L("缓存已清理。", "Cache cleared.") && notifications == 1)
        check(try Data(contentsOf:prefs) == saved && Data(contentsOf:installed) == saved)
        do {
            _ = try await policy.forecastEvaluationStore!.records(session:oldSession,at:now)
            preconditionFailure("A clear must invalidate a previously captured evaluation token")
        } catch UsageForecastEvaluationStoreFailure.staleGeneration { }

        // A later pet-cache failure must still clear forecast leaves and notify
        // the model immediately. The deliberately linked target is preserved.
        let (failurePolicy,failureController,failureSession)=try await fixture("pet-failure")
        let target=root.appendingPathComponent("synthetic-link-target",isDirectory:true)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        try saved.write(to:target.appendingPathComponent("keep.txt"))
        let petDirectory=failurePolicy.cache.directory
        try FileManager.default.removeItem(at:petDirectory)
        try FileManager.default.createSymbolicLink(at:petDirectory,withDestinationURL:target)
        let failed=ApplicationStorageModel(storage:failurePolicy)
        failed.clear(using:failureController,includingUsageHistory:true);await failed.finish()
        check(failed.message == L("缓存未能完全清理，请重试。", "Could not clear all cached data. Try again.")
            && notifications == 2 && !failed.clearing)
        check(try await failurePolicy.forecastCache!.byteCount() == 0)
        check(try await failurePolicy.forecastEvaluationStore!.byteCount() == 0)
        check(try Data(contentsOf:target.appendingPathComponent("keep.txt")) == saved)
        do {
            _ = try await failurePolicy.forecastEvaluationStore!.records(session:failureSession,at:now)
            preconditionFailure("Partial cleanup must still invalidate old research tokens")
        } catch UsageForecastEvaluationStoreFailure.staleGeneration { }
        check(try Data(contentsOf:prefs) == saved && Data(contentsOf:installed) == saved)
        print("Forecast storage integration passed: two-leaf accounting without double count, evaluation-before-history clear, private synthetic storage, stale-token refusal, notification before pet-cache failure, saved settings and installed-pet preservation")
    }
}
