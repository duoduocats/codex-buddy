import Foundation
import Darwin

// These classifications are curated authority supplied by the feed integration.
// No title/body keyword matching can turn a credit grant into a quota reset.
enum TiboResetCompletionKind: String { case immediateQuotaReset, credits, other, unknown }
struct TiboResetResearchEvent: Equatable {
    let record: ResetAnnouncement
    let canonicalEventID: String?
    let completionKind: TiboResetCompletionKind
    let verifiedGlobalScopeID: String?
    let campaignID: String?

    init(record: ResetAnnouncement, canonicalEventID: String? = nil,
         completionKind: TiboResetCompletionKind = .unknown,
         verifiedGlobalScopeID: String? = nil, campaignID: String? = nil) {
        self.record = record; self.canonicalEventID = canonicalEventID
        self.completionKind = completionKind; self.verifiedGlobalScopeID = verifiedGlobalScopeID
        self.campaignID = campaignID
    }
    static func fromFeed(_ record: ResetAnnouncement) -> Self {
        let completion: TiboResetCompletionKind
        switch record.resetEffect {
        case .immediateQuotaReset: completion = .immediateQuotaReset
        case .credits: completion = .credits
        case .other: completion = .other
        case nil: completion = .unknown
        }
        return .init(record: record, canonicalEventID: record.relatedEventID ?? record.id,
            completionKind: completion, verifiedGlobalScopeID: record.globalScopeID, campaignID: record.campaignID)
    }
}
enum TiboResetCadenceExclusion: String, Hashable {
    case duplicate, conflictingRevision, invalidRecord, notCompletedGlobalRecord
    case notImmediateQuotaReset, unknownGlobalScope, unknownCampaign, collectedClock, unverifiedSource
}
struct TiboResetAnnouncementEstimate: Equatable {
    // A descriptive publication-clock range, never an account arrival date or
    // confidence interval. The next actual intervention is not promised.
    let earliest: Date
    let latest: Date
    let sourceSampleCount: Int
    let intervalCount: Int
    let isPast: Bool
}
struct TiboResetCadenceCohort: Equatable, Identifiable {
    let scopeID: String
    let campaignID: String
    let canonicalEventIDs: [String]
    let announcementDates: [Date]
    let sourceURLs: [URL]
    let intervals: [TimeInterval]
    let meanInterval: TimeInterval?
    let medianInterval: TimeInterval?
    let announcementEstimate: TiboResetAnnouncementEstimate?
    var id: String { scopeID + ":" + campaignID }
    var sampleCount: Int { announcementDates.count }
    var hasSufficientHistory: Bool { announcementEstimate != nil }
}
struct TiboResetCadence: Equatable {
    static let minimumSamples = 3
    let cohorts: [TiboResetCadenceCohort]
    let exclusions: [TiboResetCadenceExclusion: Int]
    let inputLimitExceeded: Bool
    var verifiedGlobalCompletionCount: Int { cohorts.reduce(0) { $0 + $1.sampleCount } }
    var hasSufficientHistory: Bool { cohorts.contains { $0.hasSufficientHistory } }

    init(events: [TiboResetResearchEvent], now: Date) {
        guard ForecastResearchValidation.date(now), events.count <= 512 else {
            cohorts = []; exclusions = [:]; inputLimitExceeded = true; return
        }
        inputLimitExceeded = false
        var excluded = [TiboResetCadenceExclusion: Int]()
        func reject(_ reason: TiboResetCadenceExclusion, _ count: Int = 1) { excluded[reason, default: 0] += count }
        // Union aliases before choosing revisions: an explicit canonical event
        // joins a completion reply to its parent; x/twitter aliases join by post.
        var groups = [(keys: Set<String>, events: [TiboResetResearchEvent])]()
        for event in events {
            let record = event.record
            guard ForecastResearchValidation.identifier(record.id, limit: 80), (1...1_000_000).contains(record.revision),
                  event.canonicalEventID.map({ ForecastResearchValidation.identifier($0, limit: 100) }) ?? true else {
                reject(.invalidRecord); continue
            }
            let canonical = event.canonicalEventID ?? Self.postID(record.sourceURL) ?? record.id
            var keys: Set<String> = ["event:" + canonical]
            if let source = Self.postID(record.sourceURL) { keys.insert("post:" + source) }
            let matches = groups.indices.filter { !groups[$0].keys.isDisjoint(with: keys) }
            var combined = [event]
            for index in matches.reversed() {
                keys.formUnion(groups[index].keys); combined += groups[index].events; groups.remove(at: index)
            }
            groups.append((keys, combined))
        }
        var accepted = [(event: TiboResetResearchEvent, canonical: String)]()
        for group in groups {
            let highest = group.events.map { $0.record.revision }.max()!
            let latest = group.events.filter { $0.record.revision == highest }
            reject(.duplicate, group.events.count - 1)
            guard let event = latest.first, latest.allSatisfy({ Self.equivalentRevision($0, event) }) else {
                reject(.conflictingRevision); continue
            }
            let record = event.record
            let explicitlyGlobalReset = record.type == "globalReset"
                || (record.type == "message" && record.resetEffect == .immediateQuotaReset)
            guard explicitlyGlobalReset, record.status == .completed else { reject(.notCompletedGlobalRecord); continue }
            guard event.completionKind == .immediateQuotaReset else { reject(.notImmediateQuotaReset); continue }
            guard let scope = event.verifiedGlobalScopeID, ForecastResearchValidation.identifier(scope, limit: 80),
                  let applies = record.appliesToText, !applies.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !applies.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { reject(.unknownGlobalScope); continue }
            guard let campaign = event.campaignID, ForecastResearchValidation.identifier(campaign, limit: 80) else {
                reject(.unknownCampaign); continue
            }
            guard record.timestampBasis == .source else { reject(.collectedClock); continue }
            guard Self.postID(record.sourceURL) != nil else { reject(.unverifiedSource); continue }
            guard ForecastResearchValidation.date(record.publishedAt), record.publishedAt <= now else { reject(.invalidRecord); continue }
            accepted.append((event, event.canonicalEventID ?? Self.postID(record.sourceURL) ?? record.id))
        }
        let grouped = Dictionary(grouping: accepted) { $0.event.verifiedGlobalScopeID! + ":" + $0.event.campaignID! }
        cohorts = grouped.keys.sorted().map { key in
            let rows = grouped[key]!.sorted {
                if $0.event.record.publishedAt != $1.event.record.publishedAt { return $0.event.record.publishedAt < $1.event.record.publishedAt }
                return $0.canonical < $1.canonical
            }
            let dates = rows.map { $0.event.record.publishedAt }
            let intervals = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }
            let usable = rows.count >= Self.minimumSamples && intervals.allSatisfy { $0.isFinite && $0 > 0 }
            let sorted = intervals.sorted()
            let mean = usable ? intervals.reduce(0, +) / Double(intervals.count) : nil
            let median: Double? = usable ? (sorted.count % 2 == 0
                ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]) : nil
            let estimate: TiboResetAnnouncementEstimate?
            if usable, let last = dates.last, let firstInterval = sorted.first, let lastInterval = sorted.last {
                let earliest = last.addingTimeInterval(firstInterval), latest = last.addingTimeInterval(lastInterval)
                estimate = ForecastResearchValidation.date(latest)
                    ? .init(earliest: earliest, latest: latest, sourceSampleCount: dates.count,
                            intervalCount: intervals.count, isPast: latest < now) : nil
            } else { estimate = nil }
            return .init(scopeID: rows[0].event.verifiedGlobalScopeID!, campaignID: rows[0].event.campaignID!,
                canonicalEventIDs: rows.map(\.canonical), announcementDates: dates,
                sourceURLs: rows.compactMap { $0.event.record.sourceURL }, intervals: intervals,
                meanInterval: mean, medianInterval: median, announcementEstimate: estimate)
        }
        exclusions = excluded.filter { $0.value > 0 }
    }
    private static func equivalentRevision(_ first: TiboResetResearchEvent, _ second: TiboResetResearchEvent) -> Bool {
        if first == second { return true }
        let a = first.record, b = second.record
        return first.completionKind == second.completionKind && first.verifiedGlobalScopeID == second.verifiedGlobalScopeID
            && first.campaignID == second.campaignID && a.revision == b.revision && a.type == b.type
            && a.status == b.status && a.scheduledAt == b.scheduledAt && a.publishedAt == b.publishedAt
            && a.timestampBasis == b.timestampBasis && a.titleText == b.titleText && a.bodyText == b.bodyText
            && a.appliesToText == b.appliesToText && postID(a.sourceURL) != nil && postID(a.sourceURL) == postID(b.sourceURL)
    }
    private static func postID(_ url: URL?) -> String? {
        guard let url, ResetAnnouncementDocument.validSourceURL(url),
              ["x.com", "twitter.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0].lowercased() == "thsottiaux" else { return nil }
        return String(parts[2])
    }
}

enum UsageForecastPredictionOrigin: String, Codable { case baseline, counterfactual }
struct UsageForecastIssuedPrediction: Codable, Equatable, Identifiable {
    let id: String
    let windowID: UsageForecastWindowID
    let issuedAt: Date
    let inputCutoff: Date
    let modelVersion: String
    // The expected reset instant identifies the quota cycle, not a Tibo plan.
    let windowResetEpoch: Date
    let predictedExhaustionAt: Date?
    let rate: Double?
    let remaining: Double
    let origin: UsageForecastPredictionOrigin
    let windowDurationMins: Int?
    let planType: String?
    let source: String?
    let segmentID: String?

    init(id: String = UUID().uuidString, windowID: UsageForecastWindowID, issuedAt: Date,
         inputCutoff: Date, modelVersion: String, windowResetEpoch: Date,
         predictedExhaustionAt: Date?, rate: Double?, remaining: Double,
         origin: UsageForecastPredictionOrigin = .baseline, windowDurationMins: Int? = nil,
         planType: String? = nil, source: String? = nil, segmentID: String? = nil) {
        self.id = id; self.windowID = windowID; self.issuedAt = issuedAt; self.inputCutoff = inputCutoff
        self.modelVersion = modelVersion; self.windowResetEpoch = windowResetEpoch
        self.predictedExhaustionAt = predictedExhaustionAt; self.rate = rate; self.remaining = remaining; self.origin = origin
        self.windowDurationMins = windowDurationMins; self.planType = planType; self.source = source; self.segmentID = segmentID
    }
    fileprivate var valid: Bool {
        ForecastResearchValidation.identifier(id, limit: 80) && ForecastResearchValidation.window(windowID)
            && ForecastResearchValidation.identifier(modelVersion, limit: 80)
            && ForecastResearchValidation.date(issuedAt) && ForecastResearchValidation.date(inputCutoff)
            && ForecastResearchValidation.date(windowResetEpoch) && inputCutoff <= issuedAt
            && windowResetEpoch > issuedAt && remaining.isFinite && (0...100).contains(remaining)
            && (rate.map { $0.isFinite && $0 >= 0 } ?? true)
            && (windowDurationMins.map { (1...525_600).contains($0) } ?? true)
            && (planType.map { ForecastResearchValidation.identifier($0, limit: 64) } ?? true)
            && (source.map { ForecastResearchValidation.identifier($0, limit: 48) } ?? true)
            && (segmentID.map(ForecastResearchValidation.segment) ?? true)
            && (predictedExhaustionAt.map { ForecastResearchValidation.date($0) && $0 >= issuedAt } ?? true)
    }
}
enum UsageForecastCensorReason: String, Codable {
    case invalidInput, staleInput, counterfactual, noEstimate, nonpositiveRate, alreadyExhausted
    case inputMismatch, conflictingObservations, resetBeforeDepletion, observationGap
    case staleObservations, quotaChanged, contextChanged
}
struct UsageForecastDepletionScore: Codable, Equatable {
    let observedLower: Date
    let observedUpper: Date
    // Exact depletion is unknown within this observed interval. A zero minimum
    // error means compatible with the interval, not "100% accurate".
    let minimumAbsoluteError: TimeInterval
    let maximumAbsoluteError: TimeInterval
    let observedRateLower: Double
    let observedRateUpper: Double?
}
enum UsageForecastEvaluation: Codable, Equatable {
    case pending
    case scored(UsageForecastDepletionScore)
    case censored(UsageForecastCensorReason)
}
enum UsageForecastEvaluator {
    static let maximumInputAge: TimeInterval = 300
    static let maximumObservationGap: TimeInterval = 900
    static let maximumObservationAge: TimeInterval = 300

    static func evaluate(prediction: UsageForecastIssuedPrediction,
                         observations: [UsageForecastObservation], at: Date) -> UsageForecastEvaluation {
        guard prediction.valid, ForecastResearchValidation.date(at), prediction.issuedAt <= at else { return .censored(.invalidInput) }
        guard prediction.origin == .baseline else { return .censored(.counterfactual) }
        guard prediction.issuedAt.timeIntervalSince(prediction.inputCutoff) <= maximumInputAge else { return .censored(.staleInput) }
        guard prediction.remaining > 0 else { return .censored(.alreadyExhausted) }
        guard let rate = prediction.rate, rate > 0 else { return .censored(.nonpositiveRate) }
        guard let target = prediction.predictedExhaustionAt else { return .censored(.noEstimate) }
        // Future readings never enter either the input check or the outcome.
        let rows = observations.filter { $0.windowID == prediction.windowID
            && $0.observedAt >= prediction.inputCutoff && $0.observedAt <= at }.sorted { $0.observedAt < $1.observedAt }
        guard rows.count <= 4_096, rows.allSatisfy(ForecastResearchValidation.observation) else { return .censored(.invalidInput) }
        var unique = [UsageForecastObservation]()
        for row in rows {
            if let last = unique.last, last.observedAt == row.observedAt {
                if last != row { return .censored(.conflictingObservations) }; continue
            }
            unique.append(row)
        }
        let retainedInput = unique.first.flatMap { $0.observedAt == prediction.inputCutoff ? $0 : nil }
        if let retainedInput {
            guard abs(retainedInput.usedPercent - (100 - prediction.remaining)) <= 0.01,
                  retainedInput.resetDate == prediction.windowResetEpoch else { return .censored(.inputMismatch) }
        }
        // Coalescing later reads in the same five-minute bin can remove the
        // cutoff row. The issued record itself preserves that factual endpoint;
        // it is never inferred from future readings or a retroactively fit rate.
        let context = retainedInput ?? unique.first
        let duration = prediction.windowDurationMins ?? context?.windowDurationMins
        let plan = prediction.planType ?? context?.planType
        let source = prediction.source ?? context?.source
        let segmentID = prediction.segmentID ?? context?.segmentID
        var previousDate = prediction.inputCutoff, previousUsed = 100 - prediction.remaining
        for row in unique {
            // Stop before the expected reset, even if the next reading still
            // contains the old 100% value. Never invent a reset credit arrival.
            if row.observedAt >= prediction.windowResetEpoch || row.resetDate != prediction.windowResetEpoch {
                return .censored(.resetBeforeDepletion)
            }
            if row.windowDurationMins != duration || row.planType != plan || row.source != source
                || (segmentID != nil && row.segmentID != segmentID) {
                return .censored(.contextChanged)
            }
            if row.observedAt.timeIntervalSince(previousDate) > maximumObservationGap { return .censored(.observationGap) }
            if row.usedPercent < previousUsed - 0.01 { return .censored(.quotaChanged) }
            if row.usedPercent >= 100 {
                guard row.observedAt > prediction.issuedAt else { return .censored(.alreadyExhausted) }
                let low = previousDate, high = row.observedAt
                let distance: Double = target < low ? low.timeIntervalSince(target) : (target > high ? target.timeIntervalSince(high) : 0)
                let maximum = max(abs(target.timeIntervalSince(low)), abs(target.timeIntervalSince(high)))
                let lowerRate = prediction.remaining / (high.timeIntervalSince(prediction.inputCutoff) / 3_600)
                let lowDuration = low.timeIntervalSince(prediction.inputCutoff)
                let upperRate = lowDuration > 0 ? prediction.remaining / (lowDuration / 3_600) : nil
                return .scored(.init(observedLower: low, observedUpper: high,
                    minimumAbsoluteError: distance, maximumAbsoluteError: maximum,
                    observedRateLower: lowerRate, observedRateUpper: upperRate))
            }
            previousDate = row.observedAt; previousUsed = row.usedPercent
        }
        if at >= prediction.windowResetEpoch { return .censored(.resetBeforeDepletion) }
        if at.timeIntervalSince(previousDate) > maximumObservationAge { return .censored(.staleObservations) }
        return .pending
    }
}

struct UsageForecastEvaluationRecord: Codable, Equatable, Identifiable {
    let prediction: UsageForecastIssuedPrediction
    let evaluation: UsageForecastEvaluation
    let evaluatedAt: Date
    var id: String { prediction.id }
}
struct UsageForecastEvaluationSummary: Equatable {
    let scoredCount: Int
    let closedCycleCount: Int
    let pendingCount: Int
    let censoredCount: Int
    let medianMinimumAbsoluteError: TimeInterval?
    init(records: [UsageForecastEvaluationRecord]) {
        struct Cycle: Hashable { let window: UsageForecastWindowID; let epoch: Date }
        var cycles = Set<Cycle>()
        var errors = [TimeInterval](), pending = 0, censored = 0
        for record in records {
            guard record.prediction.origin == .baseline else { censored += 1; continue }
            switch record.evaluation {
            case .scored(let score):
                errors.append(score.minimumAbsoluteError)
                cycles.insert(.init(window: record.prediction.windowID, epoch: record.prediction.windowResetEpoch))
            case .pending: pending += 1
            case .censored: censored += 1
            }
        }
        errors.sort(); scoredCount = errors.count; closedCycleCount = cycles.count; pendingCount = pending; censoredCount = censored
        medianMinimumAbsoluteError = errors.isEmpty ? nil : (errors.count % 2 == 0
            ? (errors[errors.count / 2 - 1] + errors[errors.count / 2]) / 2 : errors[errors.count / 2])
    }
}

private enum ForecastResearchValidation {
    static func date(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (0...4_102_444_800).contains(date.timeIntervalSince1970)
    }
    static func identifier(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= limit && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0)
        }
    }
    static func segment(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58,95,124].contains($0)
        }
    }
    static func window(_ id: UsageForecastWindowID) -> Bool { identifier(id.bucketID, limit: 80) }
    static func observation(_ row: UsageForecastObservation) -> Bool {
        window(row.windowID) && date(row.observedAt) && row.usedPercent.isFinite && (0...100).contains(row.usedPercent)
            && (row.resetDate.map(date) ?? true) && (row.windowDurationMins.map { (1...525_600).contains($0) } ?? true)
            && (row.planType.map { identifier($0, limit: 64) } ?? true) && identifier(row.source, limit: 48) && (row.segmentID.map(segment) ?? true)
    }
    private static func zipOptional(_ first: Double?, _ second: Double?) -> Bool {
        switch (first, second) { case (nil, nil): return true; case (.some(let a), .some(let b)): return abs(a - b) < 0.001; default: return false }
    }
    static func record(_ record: UsageForecastEvaluationRecord, at: Date) -> Bool {
        guard record.prediction.valid, date(record.evaluatedAt), record.prediction.issuedAt <= record.evaluatedAt,
              record.evaluatedAt <= at else { return false }
        if case .scored(let score) = record.evaluation {
            guard record.prediction.origin == .baseline, record.prediction.remaining > 0,
                  let rate = record.prediction.rate, rate > 0, let target = record.prediction.predictedExhaustionAt,
                  date(score.observedLower), date(score.observedUpper), score.observedLower >= record.prediction.inputCutoff,
                  score.observedUpper > score.observedLower, score.observedUpper > record.prediction.issuedAt,
                  score.observedUpper.timeIntervalSince(score.observedLower) <= UsageForecastEvaluator.maximumObservationGap,
                  record.prediction.issuedAt.timeIntervalSince(record.prediction.inputCutoff) <= UsageForecastEvaluator.maximumInputAge,
                  score.observedUpper <= record.evaluatedAt,
                  score.observedUpper < record.prediction.windowResetEpoch,
                  score.minimumAbsoluteError.isFinite, score.maximumAbsoluteError.isFinite,
                  score.minimumAbsoluteError >= 0, score.maximumAbsoluteError >= score.minimumAbsoluteError,
                  score.observedRateLower.isFinite, score.observedRateLower > 0,
                  (score.observedRateUpper.map { $0.isFinite && $0 >= score.observedRateLower } ?? true) else { return false }
            let minimum = target < score.observedLower ? score.observedLower.timeIntervalSince(target)
                : (target > score.observedUpper ? target.timeIntervalSince(score.observedUpper) : 0)
            let maximum = max(abs(target.timeIntervalSince(score.observedLower)), abs(target.timeIntervalSince(score.observedUpper)))
            let lowerRate = record.prediction.remaining / (score.observedUpper.timeIntervalSince(record.prediction.inputCutoff) / 3_600)
            let lowDuration = score.observedLower.timeIntervalSince(record.prediction.inputCutoff)
            let upperRate = lowDuration > 0 ? record.prediction.remaining / (lowDuration / 3_600) : nil
            let upperMatches = zipOptional(upperRate, score.observedRateUpper)
            return abs(minimum - score.minimumAbsoluteError) < 0.001 && abs(maximum - score.maximumAbsoluteError) < 0.001
                && abs(lowerRate - score.observedRateLower) < 0.001 && upperMatches
        }
        return true
    }
}

enum UsageForecastEvaluationStoreFailure: Error { case invalidData, unsafePath, tooLarge, staleGeneration, immutablePrediction }
struct UsageForecastEvaluationSession: Equatable {
    let accountKey: String
    let accountGeneration: UInt64
    let clearEpoch: UInt64
}
// Separate, bounded research records in the existing app-owned forecast folder.
// Account keys must already be salted opaque hashes; this actor never loads auth.
actor UsageForecastEvaluationStore {
    static let maximumAccounts = 4
    static let maximumRecords = 256
    static let maximumBytes = 512 * 1_024
    static let retention: TimeInterval = 28 * 86_400
    static let shared = UsageForecastEvaluationStore(directory: UsageForecastCache.shared.directory)
    let directory: URL
    private struct Account: Codable, Equatable { let key: String; var lastSeen: Date; var records: [UsageForecastEvaluationRecord] }
    private struct Document: Codable { let schemaVersion: Int; let accounts: [Account] }
    private let filename = "evaluation.json"
    private var accounts = [Account]()
    private var loaded = false
    private var failedLoad = false
    private var needsPersistence = false
    private var clearEpoch: UInt64 = 0
    private var activeAccount: String?
    private var activeGeneration: UInt64?

    init(directory: URL) { self.directory = directory }
    // The caller uses its monotonic account generation captured before a read.
    // An old task cannot reactivate a prior account or reacquire a valid token.
    func session(accountKey: String?, accountGeneration: UInt64) -> UsageForecastEvaluationSession? {
        guard UsageForecastObservation.validAccountKey(accountKey), let accountKey else { return nil }
        if let current = activeGeneration {
            guard accountGeneration >= current else { return nil }
            if accountGeneration == current, let activeAccount, activeAccount != accountKey { return nil }
        }
        activeGeneration = accountGeneration; activeAccount = accountKey
        return .init(accountKey: accountKey, accountGeneration: accountGeneration, clearEpoch: clearEpoch)
    }
    func deactivate(accountGeneration: UInt64) {
        guard activeGeneration.map({ accountGeneration >= $0 }) ?? true else { return }
        activeGeneration = accountGeneration; activeAccount = nil
    }
    func records(session: UsageForecastEvaluationSession, at: Date) throws -> [UsageForecastEvaluationRecord] {
        try validate(session); guard ForecastResearchValidation.date(at) else { throw UsageForecastEvaluationStoreFailure.invalidData }
        try load(at: at); prune(at: at)
        if needsPersistence { try write(encodedData()); needsPersistence = false }
        return accounts.first(where: { $0.key == session.accountKey })?.records ?? []
    }
    func record(_ prediction: UsageForecastIssuedPrediction, session: UsageForecastEvaluationSession,
                at: Date) throws -> [UsageForecastEvaluationRecord] {
        try Task.checkCancellation(); try validate(session)
        guard prediction.valid, ForecastResearchValidation.date(at), prediction.issuedAt <= at,
              prediction.issuedAt >= at.addingTimeInterval(-Self.retention) else { throw UsageForecastEvaluationStoreFailure.invalidData }
        try load(at: at); prune(at: at)
        if !accounts.contains(where: { $0.key == session.accountKey }) {
            accounts.append(.init(key: session.accountKey, lastSeen: at, records: []))
        }
        let index = accounts.firstIndex(where: { $0.key == session.accountKey })!
        if let prior = accounts[index].records.first(where: { $0.id == prediction.id }) {
            guard prior.prediction == prediction else { throw UsageForecastEvaluationStoreFailure.immutablePrediction }
        } else {
            let initial = UsageForecastEvaluator.evaluate(prediction: prediction, observations: [], at: at)
            accounts[index].records.append(.init(prediction: prediction, evaluation: initial, evaluatedAt: at))
        }
        accounts[index].lastSeen = at; prune(at: at, preserving: session.accountKey)
        try write(encodedData()); needsPersistence = false
        return accounts.first(where: { $0.key == session.accountKey })?.records ?? []
    }
    func evaluate(observations: [UsageForecastObservation], session: UsageForecastEvaluationSession,
                  at: Date) throws -> [UsageForecastEvaluationRecord] {
        try Task.checkCancellation(); try validate(session)
        guard ForecastResearchValidation.date(at), observations.count <= UsageForecastObservation.maximumTotalSamples else { throw UsageForecastEvaluationStoreFailure.invalidData }
        try load(at: at); prune(at: at)
        guard let index = accounts.firstIndex(where: { $0.key == session.accountKey }) else { return [] }
        for position in accounts[index].records.indices {
            let previous = accounts[index].records[position]
            guard previous.evaluatedAt <= at else { continue }
            if case .pending = previous.evaluation {
                let evaluation = UsageForecastEvaluator.evaluate(prediction: previous.prediction, observations: observations, at: at)
                accounts[index].records[position] = .init(prediction: previous.prediction, evaluation: evaluation, evaluatedAt: at)
            }
        }
        accounts[index].lastSeen = at; prune(at: at, preserving: session.accountKey)
        try write(encodedData()); needsPersistence = false
        return accounts.first(where: { $0.key == session.accountKey })?.records ?? []
    }
    func clear() throws {
        clearEpoch &+= 1; accounts = []; loaded = true; failedLoad = false; needsPersistence = false
        guard let fd = try directoryDescriptor(create: false) else { return }
        defer { Darwin.close(fd) }
        try checkLeaf(fd, enforceSize: false)
        if unlinkat(fd, filename, 0) != 0 && errno != ENOENT { throw UsageForecastEvaluationStoreFailure.unsafePath }
    }
    func byteCount() throws -> Int64 {
        guard let fd = try directoryDescriptor(create: false) else { return 0 }
        defer { Darwin.close(fd) }
        var info = stat()
        if fstatat(fd, filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return 0 }; throw UsageForecastEvaluationStoreFailure.unsafePath
        }
        try checkInfo(info); return Int64(info.st_size)
    }
    private func validate(_ session: UsageForecastEvaluationSession) throws {
        guard session.clearEpoch == clearEpoch, session.accountGeneration == activeGeneration,
              session.accountKey == activeAccount else { throw UsageForecastEvaluationStoreFailure.staleGeneration }
    }
    private func load(at: Date) throws {
        if loaded { if failedLoad { throw UsageForecastEvaluationStoreFailure.invalidData }; return }
        loaded = true
        do {
            guard let data = try read() else { return }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.schemaVersion == 1, document.accounts.count <= Self.maximumAccounts,
                  Set(document.accounts.map(\.key)).count == document.accounts.count,
                  document.accounts.reduce(0, { $0 + $1.records.count }) <= Self.maximumRecords else {
                throw UsageForecastEvaluationStoreFailure.invalidData
            }
            for account in document.accounts {
                guard UsageForecastObservation.validAccountKey(account.key), ForecastResearchValidation.date(account.lastSeen),
                      account.lastSeen <= at, Set(account.records.map(\.id)).count == account.records.count,
                      account.records.allSatisfy({ ForecastResearchValidation.record($0, at: at) }) else {
                    throw UsageForecastEvaluationStoreFailure.invalidData
                }
            }
            accounts = document.accounts; prune(at: at)
        } catch { accounts = []; failedLoad = true; throw error }
    }
    private func prune(at: Date, preserving key: String? = nil) {
        let previous = accounts
        let cutoff = at.addingTimeInterval(-Self.retention)
        for index in accounts.indices {
            accounts[index].records = accounts[index].records.filter {
                $0.prediction.issuedAt >= cutoff && $0.prediction.issuedAt <= at
            }.sorted { if $0.prediction.issuedAt != $1.prediction.issuedAt { return $0.prediction.issuedAt < $1.prediction.issuedAt }; return $0.id < $1.id }
        }
        accounts = Array(accounts.filter { !$0.records.isEmpty && $0.lastSeen >= cutoff && $0.lastSeen <= at }.sorted {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            if ($0.key == key) != ($1.key == key) { return $0.key == key }
            return $0.key < $1.key
        }.prefix(Self.maximumAccounts))
        while accounts.reduce(0, { $0 + $1.records.count }) > Self.maximumRecords { removeOldest() }
        accounts.removeAll { $0.records.isEmpty }
        if accounts != previous { needsPersistence = true }
    }
    private func removeOldest() {
        guard let index = accounts.indices.filter({ !accounts[$0].records.isEmpty }).min(by: {
            accounts[$0].records[0].prediction.issuedAt < accounts[$1].records[0].prediction.issuedAt
        }) else { return }
        accounts[index].records.removeFirst()
    }
    private func encodedData() throws -> Data {
        var data = try JSONEncoder().encode(Document(schemaVersion: 1, accounts: accounts))
        while data.count > Self.maximumBytes, accounts.contains(where: { !$0.records.isEmpty }) {
            removeOldest(); accounts.removeAll { $0.records.isEmpty }
            data = try JSONEncoder().encode(Document(schemaVersion: 1, accounts: accounts))
        }
        guard data.count <= Self.maximumBytes else { throw UsageForecastEvaluationStoreFailure.tooLarge }; return data
    }
    // Same no-follow descriptor walk as the observation cache. Reads and writes
    // never traverse a linked directory/leaf; files are private atomic replaces.
    private func directoryDescriptor(create: Bool) throws -> Int32? {
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.path != "/",
              directory.pathComponents.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw UsageForecastEvaluationStoreFailure.unsafePath
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UsageForecastEvaluationStoreFailure.unsafePath }
        for component in directory.pathComponents.dropFirst() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next >= 0 { Darwin.close(fd); fd = next; continue }
            if errno == ENOENT {
                if !create { Darwin.close(fd); return nil }
                if mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { Darwin.close(fd); throw UsageForecastEvaluationStoreFailure.unsafePath }
                let made = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard made >= 0 else { Darwin.close(fd); throw UsageForecastEvaluationStoreFailure.unsafePath }
                Darwin.close(fd); fd = made
            } else { Darwin.close(fd); throw UsageForecastEvaluationStoreFailure.unsafePath }
        }
        return fd
    }
    private func checkInfo(_ info: stat, enforceSize: Bool = true) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw UsageForecastEvaluationStoreFailure.unsafePath }
        guard info.st_size >= 0, !enforceSize || info.st_size <= Self.maximumBytes else { throw UsageForecastEvaluationStoreFailure.tooLarge }
    }
    private func checkLeaf(_ fd: Int32, enforceSize: Bool = true) throws {
        var info = stat()
        if fstatat(fd, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 { try checkInfo(info, enforceSize: enforceSize) }
        else if errno != ENOENT { throw UsageForecastEvaluationStoreFailure.unsafePath }
    }
    private func read() throws -> Data? {
        guard let directoryFD = try directoryDescriptor(create: false) else { return nil }; defer { Darwin.close(directoryFD) }
        let fd = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw UsageForecastEvaluationStoreFailure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw UsageForecastEvaluationStoreFailure.unsafePath }; try checkInfo(info)
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes, data.count == info.st_size else { throw UsageForecastEvaluationStoreFailure.tooLarge }; return data
    }
    private func write(_ data: Data) throws {
        guard data.count <= Self.maximumBytes, let directoryFD = try directoryDescriptor(create: true) else {
            throw UsageForecastEvaluationStoreFailure.tooLarge
        }
        defer { Darwin.close(directoryFD) }; try checkLeaf(directoryFD)
        let candidate = ".evaluation-" + UUID().uuidString + ".tmp"
        let fd = openat(directoryFD, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UsageForecastEvaluationStoreFailure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(directoryFD, candidate, 0) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close(); try checkLeaf(directoryFD)
        guard renameat(directoryFD, candidate, directoryFD, filename) == 0 else { throw UsageForecastEvaluationStoreFailure.unsafePath }
    }
}
