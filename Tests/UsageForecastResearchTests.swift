import Foundation
import Darwin

@main struct UsageForecastResearchTests {
    static let now = Date(timeIntervalSince1970: 1_791_734_400)
    static let window = UsageForecastWindowID(bucketID: "codex", role: .secondary)
    static let keyA = String(repeating: "a", count: 64)
    static let keyB = String(repeating: "b", count: 64)

    static func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) { precondition(condition, file: file, line: line) }
    static func main() async throws {
        cadence()
        evaluation()
        try await store()
        try await unsafeStorage()
        print("Usage forecast research tests passed: curated same-cohort >=3 source-clock resets, explicit generic-message compatibility, dedup/corrections, interval scoring, future exclusion, reset/gap/stale censorship, immutable predictions, scenario exclusion, account/clear generations, bounds/retention and unsafe storage refusal")
    }
    static func event(_ id: String, day: Double, revision: Int = 1,
                      status: ResetAnnouncementStatus = .completed,
                      type: String = "globalReset", basis: ResetTimestampBasis = .source,
                      scope: String? = "all-paid", campaign: String? = "challenge-2026",
                      kind: TiboResetCompletionKind = .immediateQuotaReset,
                      canonical: String? = nil, source: URL? = nil) -> TiboResetResearchEvent {
        let published = now.addingTimeInterval(day * 86_400)
        let record = ResetAnnouncement(id: "test-" + id, revision: revision, type: type, status: status,
            scheduledAt: nil, publishedAt: published, expiresAt: published.addingTimeInterval(30 * 86_400),
            titleText: .init(zh: "合成公告", en: "Synthetic announcement"),
            bodyText: .init(zh: "仅测试", en: "Test only"),
            appliesToText: .init(zh: "合成公开范围", en: "Synthetic public scope"),
            sourceURL: source ?? URL(string: "https://x.com/thsottiaux/status/" + id)!, timestampBasis: basis)
        return .init(record: record, canonicalEventID: canonical, completionKind: kind,
                     verifiedGlobalScopeID: scope, campaignID: campaign)
    }
    static func cadence() {
        let first = event("101", day: -10), second = event("102", day: -6), third = event("103", day: -3)
        let insufficient = TiboResetCadence(events: [first, second], now: now)
        check(insufficient.verifiedGlobalCompletionCount == 2 && !insufficient.hasSufficientHistory)
        check(insufficient.cohorts[0].meanInterval == nil && insufficient.cohorts[0].medianInterval == nil)
        let complete = TiboResetCadence(events: [third, first, second], now: now)
        check(complete.hasSufficientHistory && complete.cohorts.count == 1)
        let cohort = complete.cohorts[0]
        check(cohort.sampleCount == 3 && cohort.intervals == [4 * 86_400, 3 * 86_400])
        check(cohort.meanInterval == 3.5 * 86_400 && cohort.medianInterval == 3.5 * 86_400)
        check(cohort.announcementEstimate?.earliest == now)
        check(cohort.announcementEstimate?.latest == now.addingTimeInterval(86_400))
        check(cohort.sourceURLs.count == 3)
        let duplicates = TiboResetCadence(events: [first, first, second, third, third], now: now)
        check(duplicates.cohorts[0].sampleCount == 3 && duplicates.exclusions[.duplicate] == 2)
        let twitterAlias = event("999", day: -3, source: URL(string: "https://twitter.com/thsottiaux/status/103")!)
        let samePost = TiboResetCadence(events: [first, second, third, twitterAlias], now: now)
        check(samePost.cohorts[0].sampleCount == 3 && samePost.exclusions[.duplicate] == 1)
        let cancelled = event("103", day: -3, revision: 2, status: .cancelled)
        let revised = TiboResetCadence(events: [first, second, third, cancelled], now: now)
        check(!revised.hasSufficientHistory && revised.verifiedGlobalCompletionCount == 2)
        let equalRevisionConflict = event("103", day: -3, kind: .credits)
        let conflicted = TiboResetCadence(events: [first, second, third, equalRevisionConflict], now: now)
        check(conflicted.exclusions[.conflictingRevision] == 1 && !conflicted.hasSufficientHistory)
        let otherCampaign = event("104", day: -1, campaign: "ordinary-2026")
        let otherScope = event("105", day: -2, scope: "all-chatgpt")
        let mixed = TiboResetCadence(events: [first, second, otherCampaign, otherScope], now: now)
        check(mixed.verifiedGlobalCompletionCount == 4 && mixed.cohorts.count == 3 && !mixed.hasSufficientHistory)
        let excluded = TiboResetCadence(events: [first, second,
            event("110", day: -1, type: "message", kind: .credits),
            event("111", day: -1, kind: .credits), event("112", day: -1, scope: nil),
            event("113", day: -1, campaign: nil), event("114", day: -1, basis: .collected),
            event("115", day: -1, status: .scheduled), event("116", day: 1),
            event("117", day: -1, source: URL(string: "https://x.com/openai/status/117")!),
            event("118", day: -1, kind: .unknown)], now: now)
        check(excluded.verifiedGlobalCompletionCount == 2 && !excluded.hasSufficientHistory)
        check(excluded.exclusions[.unknownGlobalScope] == 1 && excluded.exclusions[.unknownCampaign] == 1)
        check(excluded.exclusions[.collectedClock] == 1 && excluded.exclusions[.unverifiedSource] == 1)
        let canonicalOld = event("120", day: -3, canonical: "event-3")
        let canonicalReply = event("121", day: -3, revision: 2, canonical: "event-3")
        let alias = TiboResetCadence(events: [first, second, canonicalOld, canonicalReply], now: now)
        check(alias.cohorts[0].sampleCount == 3 && alias.cohorts[0].canonicalEventIDs.last == "event-3")
        let simultaneous = TiboResetCadence(events: [first, second, event("122", day: -6)], now: now)
        check(!simultaneous.hasSufficientHistory && simultaneous.cohorts[0].meanInterval == nil)
        check(TiboResetCadence(events: Array(repeating: first, count: 513), now: now).inputLimitExceeded)
        let conservative = TiboResetResearchEvent.fromFeed(first.record)
        check(conservative.completionKind == .unknown && conservative.verifiedGlobalScopeID == nil && conservative.campaignID == nil)
        let feedRows = [first,second,third].map { old -> TiboResetResearchEvent in
            let record = old.record
            return .fromFeed(.init(id: record.id, revision: record.revision, type: record.type, status: record.status,
                scheduledAt: record.scheduledAt, publishedAt: record.publishedAt, expiresAt: record.expiresAt,
                titleText: record.titleText, bodyText: record.bodyText, appliesToText: record.appliesToText,
                sourceURL: record.sourceURL, timestampBasis: record.timestampBasis, resetEffect: .immediateQuotaReset,
                globalScopeID: "all-paid", campaignID: "challenge-2026"))
        }
        check(TiboResetCadence(events: feedRows, now: now).hasSufficientHistory)
        func genericMessage(_ old: TiboResetResearchEvent, revision: Int = 1, status: ResetAnnouncementStatus = .completed,
                            effect: ResetAnnouncementEffect? = .immediateQuotaReset, scope: String? = "all-paid",
                            campaign: String? = "challenge-2026", id: String? = nil, related: String? = nil) -> TiboResetResearchEvent {
            let record = old.record
            return .fromFeed(.init(id: id ?? record.id, revision: revision, type: "message", status: status,
                publishedAt: record.publishedAt, expiresAt: record.expiresAt, titleText: record.titleText,
                bodyText: record.bodyText, appliesToText: record.appliesToText, sourceURL: record.sourceURL,
                timestampBasis: record.timestampBasis, resetEffect: effect, globalScopeID: scope,
                campaignID: campaign, relatedEventID: related))
        }
        let messageRows = feedRows.map { genericMessage($0) }
        let messageCadence = TiboResetCadence(events: messageRows, now: now)
        check(messageCadence.hasSufficientHistory && messageCadence.verifiedGlobalCompletionCount == 3)
        let unknownMessage = genericMessage(feedRows[2], effect: nil)
        check(!TiboResetCadence(events: Array(messageRows.prefix(2)) + [unknownMessage], now: now).hasSufficientHistory)
        let missingMessageScope = genericMessage(feedRows[2], scope: nil)
        check(!TiboResetCadence(events: Array(messageRows.prefix(2)) + [missingMessageScope], now: now).hasSufficientHistory)
        let missingMessageCampaign = genericMessage(feedRows[2], campaign: nil)
        check(!TiboResetCadence(events: Array(messageRows.prefix(2)) + [missingMessageCampaign], now: now).hasSufficientHistory)
        let manualUnclassifiedMessage = TiboResetResearchEvent(record: unknownMessage.record, completionKind: .immediateQuotaReset,
            verifiedGlobalScopeID: "all-paid", campaignID: "challenge-2026")
        check(!TiboResetCadence(events: Array(messageRows.prefix(2)) + [manualUnclassifiedMessage], now: now).hasSufficientHistory)
        let cancellationAlias = genericMessage(feedRows[2], revision: 2, status: .cancelled,
            id: "cancel-completion-alias", related: feedRows[2].record.id)
        let cancelledMessage = TiboResetCadence(events: messageRows + [cancellationAlias], now: now)
        check(cancelledMessage.verifiedGlobalCompletionCount == 2 && !cancelledMessage.hasSufficientHistory)
        let creditFeed = TiboResetResearchEvent.fromFeed(.init(id: "credit-grant", revision: 1, type: "message", status: .completed,
            publishedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(3_600),
            titleText: .init(zh: "全球重置", en: "Global reset"), bodyText: .init(zh: "已完成", en: "Done"),
            sourceURL: URL(string: "https://x.com/thsottiaux/status/900")!, resetEffect: .credits, campaignID: "challenge-2026"))
        check(creditFeed.completionKind == .credits && !TiboResetCadence(events: [creditFeed], now: now).hasSufficientHistory)
        check(TiboResetCadence(events: [conservative], now: now).verifiedGlobalCompletionCount == 0)
    }
    static func prediction(id: String = "issued", issue: Date = now, cutoff: Date? = nil,
                           reset: Date? = nil, target: Date? = nil, rate: Double? = 360,
                           remaining: Double = 30, origin: UsageForecastPredictionOrigin = .baseline, segmentID: String? = nil) -> UsageForecastIssuedPrediction {
        .init(id: id, windowID: window, issuedAt: issue, inputCutoff: cutoff ?? issue, modelVersion: "pace-v1",
            windowResetEpoch: reset ?? issue.addingTimeInterval(3_600),
            predictedExhaustionAt: target ?? issue.addingTimeInterval(300), rate: rate, remaining: remaining, origin: origin, windowDurationMins: 10_080, planType: "plus", source: "native-wham", segmentID: segmentID)
    }
    static func reading(_ offset: Double, used: Double, reset: Date? = nil,
                        duration: Int? = 10_080, source: String = "native-wham", plan: String? = "plus") -> UsageForecastObservation {
        .init(windowID: window, observedAt: now.addingTimeInterval(offset), usedPercent: used,
              windowDurationMins: duration, resetDate: reset ?? now.addingTimeInterval(3_600), planType: plan, source: source)
    }
    static func evaluate(_ p: UsageForecastIssuedPrediction, _ rows: [UsageForecastObservation], offset: Double) -> UsageForecastEvaluation {
        UsageForecastEvaluator.evaluate(prediction: p, observations: rows, at: now.addingTimeInterval(offset))
    }
    static func evaluation() {
        let p = prediction(), rows = [reading(0, used: 70), reading(240, used: 95), reading(330, used: 100)]
        guard case .scored(let score) = evaluate(p, rows, offset: 330) else { preconditionFailure("observed depletion must score") }
        check(score.observedLower == now.addingTimeInterval(240) && score.observedUpper == now.addingTimeInterval(330))
        check(score.minimumAbsoluteError == 0 && score.maximumAbsoluteError == 60)
        check(abs(score.observedRateLower - 30 / (330.0 / 3_600)) < 0.0001 && score.observedRateUpper == 450)
        // The issued cutoff endpoint survives even when coalescing removes its row.
        check(evaluate(p, Array(rows.dropFirst()), offset: 330) == .scored(score))
        let tooEarly = prediction(target: now.addingTimeInterval(120))
        guard case .scored(let earlyScore) = evaluate(tooEarly, rows, offset: 330) else { preconditionFailure() }
        check(earlyScore.minimumAbsoluteError == 120 && earlyScore.maximumAbsoluteError == 210)
        let tooLate = prediction(target: now.addingTimeInterval(500))
        guard case .scored(let lateScore) = evaluate(tooLate, rows, offset: 330) else { preconditionFailure() }
        check(lateScore.minimumAbsoluteError == 170 && lateScore.maximumAbsoluteError == 260)
        // A later actual record cannot leak into an earlier evaluation.
        check(evaluate(p, rows + [reading(600, used: 100)], offset: 240) == .pending)
        check(evaluate(p, Array(rows.prefix(2)), offset: 240) == .pending)
        check(evaluate(p, [rows[0]], offset: 301) == .censored(.staleObservations))
        check(evaluate(p, [rows[0], reading(901, used: 100)], offset: 901) == .censored(.observationGap))
        check(evaluate(p, [rows[0], reading(300, used: 1)], offset: 300) == .censored(.quotaChanged))
        check(evaluate(p, [rows[0], reading(300, used: 100, reset: now.addingTimeInterval(7_200))], offset: 300) == .censored(.resetBeforeDepletion))
        check(evaluate(p, [rows[0], reading(3_600, used: 100)], offset: 3_600) == .censored(.resetBeforeDepletion))
        check(evaluate(p, [rows[0]], offset: 3_600) == .censored(.resetBeforeDepletion))
        check(evaluate(p, [rows[0], reading(300, used: 100, duration: 300)], offset: 300) == .censored(.contextChanged))
        check(evaluate(p, [rows[0], reading(300, used: 100, source: "other")], offset: 300) == .censored(.contextChanged))
        check(evaluate(p, [rows[0], reading(300, used: 100, plan: "pro")], offset: 300) == .censored(.contextChanged))
        var segmentA = reading(240, used: 95); segmentA.segmentID = "segment-A"
        var segmentB = reading(330, used: 100); segmentB.segmentID = "segment-B"
        check(evaluate(prediction(segmentID: "segment-A"), [segmentA, segmentB], offset: 330) == .censored(.contextChanged))
        check(evaluate(prediction(segmentID: "segment-A"), [segmentB], offset: 330) == .censored(.contextChanged))
        check(evaluate(p, [reading(0, used: 69)], offset: 0) == .censored(.inputMismatch))
        check(evaluate(p, [rows[0], reading(0, used: 71)], offset: 0) == .censored(.conflictingObservations))
        check(evaluate(p, [rows[0], rows[0], rows[1]], offset: 240) == .pending)
        check(evaluate(prediction(rate: 0), rows, offset: 330) == .censored(.nonpositiveRate))
        check(evaluate(prediction(remaining: 0), rows, offset: 330) == .censored(.alreadyExhausted))
        check(evaluate(prediction(origin: .counterfactual), rows, offset: 330) == .censored(.counterfactual))
        check(evaluate(prediction(cutoff: now.addingTimeInterval(-301)), rows, offset: 330) == .censored(.staleInput))
        check(evaluate(prediction(cutoff: now.addingTimeInterval(1)), rows, offset: 330) == .censored(.invalidInput))
        check(evaluate(prediction(rate: .nan), rows, offset: 330) == .censored(.invalidInput))
        check(evaluate(p, rows, offset: -1) == .censored(.invalidInput))
        let noEstimate = UsageForecastIssuedPrediction(id: "no-estimate", windowID: window, issuedAt: now, inputCutoff: now,
            modelVersion: "pace-v1", windowResetEpoch: now.addingTimeInterval(3_600), predictedExhaustionAt: nil, rate: 1, remaining: 30)
        check(evaluate(noEstimate, rows, offset: 330) == .censored(.noEstimate))
        let firstCrossing = [reading(0, used: 70), reading(300, used: 100)]
        guard case .scored(let broad) = evaluate(p, firstCrossing, offset: 300) else { preconditionFailure() }
        check(broad.observedRateUpper == nil && broad.observedLower == now)
        let summary = UsageForecastEvaluationSummary(records: [
            .init(prediction: p, evaluation: .scored(score), evaluatedAt: now.addingTimeInterval(330)),
            .init(prediction: p, evaluation: .pending, evaluatedAt: now),
            .init(prediction: p, evaluation: .censored(.counterfactual), evaluatedAt: now)])
        check(summary.scoredCount == 1 && summary.closedCycleCount == 1 && summary.pendingCount == 1 && summary.censoredCount == 1)
        check(summary.medianMinimumAbsoluteError == 0)
        let forgedScenario = UsageForecastEvaluationSummary(records: [
            .init(prediction: prediction(origin: .counterfactual), evaluation: .scored(score), evaluatedAt: now.addingTimeInterval(330))])
        check(forgedScenario.scoredCount == 0 && forgedScenario.closedCycleCount == 0 && forgedScenario.censoredCount == 1)
    }
    static func rootDirectory(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/buddy-research-" + name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    static func expectFailure(_ expected: UsageForecastEvaluationStoreFailure, _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("expected failure") }
        catch let actual as UsageForecastEvaluationStoreFailure {
            switch (actual, expected) {
            case (.staleGeneration, .staleGeneration), (.immutablePrediction, .immutablePrediction), (.invalidData, .invalidData),
                 (.unsafePath, .unsafePath), (.tooLarge, .tooLarge): break
            default: preconditionFailure("wrong cache failure: \(actual)")
            }
        } catch { preconditionFailure("unexpected error: \(error)") }
    }
    static func store() async throws {
        let root = try rootDirectory("store"); defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageForecastEvaluationStore(directory: root)
        let tokenA = await store.session(accountKey: keyA, accountGeneration: 1)!
        check(await store.session(accountKey: "private-account@example.invalid", accountGeneration: 2) == nil)
        var records = try await store.record(prediction(), session: tokenA, at: now)
        check(records.count == 1 && records[0].evaluation == .pending)
        records = try await store.record(prediction(), session: tokenA, at: now)
        check(records.count == 1)
        await expectFailure(.immutablePrediction) { _ = try await store.record(prediction(rate: 361), session: tokenA, at: now) }
        records = try await store.evaluate(observations: [reading(0, used: 70), reading(240, used: 95), reading(330, used: 100)],
                                           session: tokenA, at: now.addingTimeInterval(330))
        guard case .scored = records[0].evaluation else { preconditionFailure() }
        let frozen = records[0]
        records = try await store.evaluate(observations: [], session: tokenA, at: now.addingTimeInterval(600))
        check(records[0] == frozen)
        let scenarioRecords = try await store.record(prediction(id: "scenario", origin: .counterfactual), session: tokenA, at: now.addingTimeInterval(600))
        check(scenarioRecords.first(where: { $0.id == "scenario" })?.evaluation == .censored(.counterfactual))
        let tokenB = await store.session(accountKey: keyB, accountGeneration: 2)!
        check(try await store.records(session: tokenB, at: now.addingTimeInterval(600)).isEmpty)
        await expectFailure(.staleGeneration) { _ = try await store.record(prediction(id: "late-a"), session: tokenA, at: now) }
        check(await store.session(accountKey: keyA, accountGeneration: 1) == nil)
        _ = try await store.record(prediction(id: "b"), session: tokenB, at: now.addingTimeInterval(600))
        let reader = UsageForecastEvaluationStore(directory: root)
        let readerA = await reader.session(accountKey: keyA, accountGeneration: 1)!
        let reloaded = try await reader.records(session: readerA, at: now.addingTimeInterval(600))
        check(reloaded.count == 2 && reloaded.first(where: { $0.id == frozen.id }) == frozen)
        let file = root.appendingPathComponent("evaluation.json")
        let bytes = try Data(contentsOf: file)
        check(bytes.count < UsageForecastEvaluationStore.maximumBytes)
        let text = String(data: bytes, encoding: .utf8)!
        check(!text.contains("private-account") && !text.contains("access_token") && !text.contains("bodyText"))
        var info = stat(); check(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let unrelatedHistory = root.appendingPathComponent("history.json")
        let historyMarker = Data("synthetic observation cache marker".utf8); try historyMarker.write(to: unrelatedHistory)
        try await store.clear()
        check(try Data(contentsOf: unrelatedHistory) == historyMarker)
        await expectFailure(.staleGeneration) { _ = try await store.record(prediction(id: "clear-late"), session: tokenB, at: now) }
        let tokenAfterClear = await store.session(accountKey: keyB, accountGeneration: 2)!
        check(try await store.records(session: tokenAfterClear, at: now).isEmpty)
        check(try await store.byteCount() == 0)
        await store.deactivate(accountGeneration: 3)
        await expectFailure(.staleGeneration) { _ = try await store.records(session: tokenAfterClear, at: now) }
        check(await store.session(accountKey: keyB, accountGeneration: 2) == nil)
        let afterDeactivate = await store.session(accountKey: keyB, accountGeneration: 3)!
        _ = try await store.record(prediction(id: "restored"), session: afterDeactivate, at: now)
        let expired = try await store.records(session: afterDeactivate, at: now.addingTimeInterval(29 * 86_400))
        check(expired.isEmpty)
        let expiredDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        check((expiredDocument["accounts"] as! [Any]).isEmpty)
        let boundsRoot = root.appendingPathComponent("bounds", isDirectory: true)
        let bounded = UsageForecastEvaluationStore(directory: boundsRoot)
        for account in 0..<5 {
            let accountKey = String(repeating: String(account), count: 64)
            let token = await bounded.session(accountKey: accountKey, accountGeneration: UInt64(account))!
            _ = try await bounded.record(prediction(id: "account-\(account)"), session: token, at: now.addingTimeInterval(Double(account)))
        }
        let oldAccountToken = await bounded.session(accountKey: String(repeating: "0", count: 64), accountGeneration: 6)!
        check(try await bounded.records(session: oldAccountToken, at: now.addingTimeInterval(5)).isEmpty)
        let boundedToken = await bounded.session(accountKey: keyA, accountGeneration: 7)!
        for index in 0..<270 {
            _ = try await bounded.record(prediction(id: "prediction-\(index)", issue: now.addingTimeInterval(Double(index))),
                                         session: boundedToken, at: now.addingTimeInterval(Double(index + 6)))
        }
        let kept = try await bounded.records(session: boundedToken, at: now.addingTimeInterval(300))
        check(kept.count <= 256 && kept.last?.id == "prediction-269")
        let boundData = try Data(contentsOf: boundsRoot.appendingPathComponent("evaluation.json"))
        let document = try JSONSerialization.jsonObject(with: boundData) as! [String: Any]
        let accounts = document["accounts"] as! [[String: Any]]
        check(accounts.count <= 4 && accounts.reduce(0, { $0 + ($1["records"] as! [Any]).count }) <= 256)
        check(try await bounded.byteCount() <= Int64(UsageForecastEvaluationStore.maximumBytes))
    }
    struct FixtureAccount: Codable { let key: String; let lastSeen: Date; let records: [UsageForecastEvaluationRecord] }
    struct FixtureDocument: Codable { let schemaVersion: Int; let accounts: [FixtureAccount] }
    static func unsafeStorage() async throws {
        let root = try rootDirectory("paths"); defer { try? FileManager.default.removeItem(at: root) }
        func cache(_ directory: URL) async -> (UsageForecastEvaluationStore, UsageForecastEvaluationSession) {
            let store = UsageForecastEvaluationStore(directory: directory)
            return (store, await store.session(accountKey: keyA, accountGeneration: 1)!)
        }
        let corrupt = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: corrupt.appendingPathComponent("evaluation.json"))
        let (bad, badToken) = await cache(corrupt)
        do { _ = try await bad.records(session: badToken, at: now); preconditionFailure() } catch { }
        await expectFailure(.invalidData) { _ = try await bad.record(prediction(), session: badToken, at: now) }
        try await bad.clear()
        let healed = await bad.session(accountKey: keyA, accountGeneration: 1)!
        _ = try await bad.record(prediction(), session: healed, at: now)
        let oversized = root.appendingPathComponent("oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
        try Data(repeating: 32, count: UsageForecastEvaluationStore.maximumBytes + 1).write(to: oversized.appendingPathComponent("evaluation.json"))
        let (large, largeToken) = await cache(oversized)
        await expectFailure(.tooLarge) { _ = try await large.records(session: largeToken, at: now) }
        let normalRecord = UsageForecastEvaluationRecord(prediction: prediction(), evaluation: .pending, evaluatedAt: now)
        let futureRecord = UsageForecastEvaluationRecord(prediction: prediction(issue: now.addingTimeInterval(1)),
            evaluation: .pending, evaluatedAt: now.addingTimeInterval(1))
        let forgedScore = UsageForecastDepletionScore(observedLower: now.addingTimeInterval(200),
            observedUpper: now.addingTimeInterval(300), minimumAbsoluteError: 0, maximumAbsoluteError: 100,
            observedRateLower: 360, observedRateUpper: 540)
        let forgedScenario = UsageForecastEvaluationRecord(prediction: prediction(origin: .counterfactual),
            evaluation: .scored(forgedScore), evaluatedAt: now.addingTimeInterval(300))
        let fixtures = [
            FixtureDocument(schemaVersion: 2, accounts: []),
            FixtureDocument(schemaVersion: 1, accounts: [.init(key: "not-opaque", lastSeen: now, records: [normalRecord])]),
            FixtureDocument(schemaVersion: 1, accounts: (0..<5).map { .init(key: String(repeating: String($0), count: 64), lastSeen: now, records: [normalRecord]) }),
            FixtureDocument(schemaVersion: 1, accounts: [.init(key: keyA, lastSeen: now, records: [futureRecord])]),
            FixtureDocument(schemaVersion: 1, accounts: [.init(key: keyA, lastSeen: now, records: [forgedScenario])]),
            FixtureDocument(schemaVersion: 1, accounts: [.init(key: keyA, lastSeen: now, records: [normalRecord, normalRecord])])
        ]
        for (index, fixture) in fixtures.enumerated() {
            let path = root.appendingPathComponent("invalid-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try JSONEncoder().encode(fixture).write(to: path.appendingPathComponent("evaluation.json"))
            let (invalid, token) = await cache(path)
            let fixtureAt = index == 4 ? now.addingTimeInterval(300) : now
            await expectFailure(.invalidData) { _ = try await invalid.records(session: token, at: fixtureAt) }
        }
        let target = root.appendingPathComponent("untouched.json")
        let marker = Data("preserve".utf8); try marker.write(to: target)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("evaluation.json"), withDestinationURL: target)
        let (linkStore, linkToken) = await cache(linked)
        await expectFailure(.unsafePath) { _ = try await linkStore.record(prediction(), session: linkToken, at: now) }
        await expectFailure(.unsafePath) { try await linkStore.clear() }
        check(try Data(contentsOf: target) == marker)
        let directoryAlias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: linked)
        let (aliasStore, aliasToken) = await cache(directoryAlias.appendingPathComponent("child"))
        await expectFailure(.unsafePath) { _ = try await aliasStore.record(prediction(), session: aliasToken, at: now) }
        let hard = root.appendingPathComponent("hard", isDirectory: true)
        try FileManager.default.createDirectory(at: hard, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: target, to: hard.appendingPathComponent("evaluation.json"))
        let (hardStore, hardToken) = await cache(hard)
        await expectFailure(.unsafePath) { _ = try await hardStore.record(prediction(), session: hardToken, at: now) }
        check(try Data(contentsOf: target) == marker)
    }
}
