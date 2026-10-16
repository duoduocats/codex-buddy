import Foundation
import Darwin

enum UsageForecastWindowRole: String, Codable, CaseIterable { case primary, secondary }

struct UsageForecastWindowID: Codable, Equatable, Hashable, Identifiable {
    let bucketID: String
    let role: UsageForecastWindowRole
    var id: String { bucketID + "." + role.rawValue }
}

struct UsageForecastObservation: Codable, Equatable {
    static let maximumSamplesPerWindow=2304
    static let maximumTotalSamples=maximumSamplesPerWindow*8
    let windowID: UsageForecastWindowID
    let observedAt: Date
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetDate: Date?
    let planType: String?
    let source: String
    // A civil quota segment identifier contains only the already sanitized
    // window context and first sample. It survives bounded oldest-bin pruning.
    var segmentID: String? = nil

    // The opaque partition is supplied by the existing authenticated request.
    // It is validated here but never attached to individual observations.
    static func sanitized(usage: UsageResponse, accountKey: String?, at: Date,
                          source: String = "native-wham") -> [UsageForecastObservation] {
        guard validAccountKey(accountKey), validDate(at), validIdentifier(source, limit: 48) else { return [] }
        var result = [UsageForecastObservation]()
        for (key, bucket) in usage.buckets.prefix(8) {
            guard validIdentifier(key, limit: 80), bucket.planType.map({ validIdentifier($0, limit: 64) }) ?? true else { continue }
            for role in UsageForecastWindowRole.allCases {
                guard let window = role == .primary ? bucket.primary : bucket.secondary,
                      window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                      window.windowDurationMins.map({ (1...525_600).contains($0) }) ?? true else { continue }
                result.append(UsageForecastObservation(windowID: .init(bucketID: key, role: role), observedAt: at,
                    usedPercent: window.usedPercent, windowDurationMins: window.windowDurationMins,
                    resetDate: window.resetDate.flatMap { validDate($0) ? $0 : nil }, planType: bucket.planType, source: source))
            }
        }
        return Array(result.prefix(8))
    }

    // Synthetic demonstration only; production records successful reads.
    static func demo(usage: UsageResponse, now: Date) -> [UsageForecastObservation] {
        sanitized(usage: usage, accountKey: String(repeating: "0", count: 64), at: now, source: "synthetic").flatMap { current in
            let span: TimeInterval = (current.windowDurationMins ?? 1_440) >= 1_440 ? 21_600 : 3_600
            let movement = min(current.usedPercent, span >= 21_600 ? 12 : 6)
            let count = Int(span / 300)
            return (0...count).map { index in
                UsageForecastObservation(windowID: current.windowID,
                    observedAt: now.addingTimeInterval(Double(index - count) * 300),
                    usedPercent: current.usedPercent - movement + movement * Double(index) / Double(count),
                    windowDurationMins: current.windowDurationMins, resetDate: current.resetDate,
                    planType: current.planType, source: current.source)
            }
        }
    }

    static func merged(existing: [UsageForecastObservation], incoming: [UsageForecastObservation],
                       at: Date) -> [UsageForecastObservation] {
        let cutoff = at.addingTimeInterval(-28 * 86_400)
        var windows = [UsageForecastWindowID: [UsageForecastObservation]]()
        for reading in existing.suffix(Self.maximumTotalSamples) where reading.valid && reading.observedAt >= cutoff && reading.observedAt <= at.addingTimeInterval(60) {
            var values=windows[reading.windowID] ?? []
            if reading.segmentID != nil {values.append(reading)} else {append(reading,to:&values)}
            windows[reading.windowID]=values
        }
        for reading in incoming.prefix(8) where reading.valid && reading.observedAt >= cutoff && reading.observedAt <= at.addingTimeInterval(60) {
            var values=windows[reading.windowID] ?? [];append(reading,to:&values);windows[reading.windowID]=values
        }
        for key in windows.keys {windows[key]=bounded(windows[key]!,limit:maximumSamplesPerWindow)}
        return windows.sorted {
            ($0.value.last?.observedAt ?? .distantPast) > ($1.value.last?.observedAt ?? .distantPast)
        }.prefix(8).flatMap(\.value)
    }

    fileprivate static func append(_ reading: Self, to previous: inout [Self]) {
        if previous.last.map({ reading.sameReading(as: $0) }) == true { return }
        if let last = previous.last, last.segmentID == nil {
            // Upgrade a schema1 cache before pruning its oldest endpoint. All
            // rows in the legacy current segment must share its original
            // marker, or a later normalization could invent a reset boundary.
            var start = previous.count - 1
            while start > 0 && !previous[start].startsNewSegment(after: previous[start - 1]) { start -= 1 }
            let marker = previous[start].segmentID ?? previous[start].initialSegmentID
            for index in start..<previous.count where previous[index].segmentID == nil { previous[index].segmentID = marker }
        }
        let starts = previous.last.map { reading.startsNewSegment(after: $0) } ?? true
        var retained = reading
        retained.segmentID = starts ? (reading.segmentID == previous.last?.segmentID ? nil : reading.segmentID) ?? reading.initialSegmentID
            : previous.last?.segmentID ?? reading.initialSegmentID
        if !starts, let last = previous.last,
           floor(last.observedAt.timeIntervalSince1970 / 300) == floor(reading.observedAt.timeIntervalSince1970 / 300) {
            // Keep the first observed endpoint as well as the latest real
            // reading in the first bin of EACH segment. Closed segments remain
            // available to evaluate a forecast issued before a later reset.
            let start = previous.lastIndex(where: { $0.segmentID != last.segmentID }).map { $0 + 1 } ?? 0
            let firstZero = previous[start...].firstIndex(where: { $0.usedPercent == 100 })
            if previous.count - start == 1 || firstZero == previous.count - 1 { previous.append(retained) }
            else { previous[previous.count - 1] = retained }
        } else { previous.append(retained) }
        previous=bounded(previous,limit:maximumSamplesPerWindow)
    }

    static func bounded(_ rows:[Self],limit:Int) -> [Self] {
        guard rows.count > limit,limit > 1 else {return limit > 0 ? Array(rows.suffix(limit)) : []}
        // Preserve observed cycle beginnings, including full-quota readings, without synthesizing data.
        var starts=[Int]()
        for i in rows.indices {if i == 0 {starts.append(i)} else if rows[i].resetDate != rows[i-1].resetDate || rows[i].windowDurationMins != rows[i-1].windowDurationMins || rows[i].planType != rows[i-1].planType || rows[i].usedPercent < rows[i-1].usedPercent-0.01 {starts.append(i)}}
        let pinned=Set(starts.suffix(min(32,max(1,limit/8))))
        var indexes=pinned
        for i in rows.indices.reversed() where indexes.count < limit {indexes.insert(i)}
        return indexes.sorted().map {rows[$0]}
    }
    static func segments(_ observations: [Self], at: Date) -> [UsageForecastObservationSegment] {
        guard validDate(at) else { return [] }
        let cutoff = at.addingTimeInterval(-28 * 86_400)
        var result = [UsageForecastObservationSegment]()
        for reading in observations.suffix(Self.maximumTotalSamples) where reading.valid
            && reading.observedAt >= cutoff && reading.observedAt <= at.addingTimeInterval(60) {
            if let last = result.last?.observations.last {
                if reading.sameReading(as: last) { continue }
                if !reading.startsNewSegment(after: last) {
                    result[result.count - 1].observations.append(reading)
                    continue
                }
            }
            result.append(.init(id: reading.segmentID ?? reading.initialSegmentID, observations: [reading]))
        }
        return result
    }

    private var initialSegmentID: String {
        let values = [windowID.bucketID, windowID.role.rawValue, source, planType ?? "",
            windowDurationMins.map(String.init) ?? "", resetDate.map { String($0.timeIntervalSince1970.bitPattern) } ?? "",
            String(observedAt.timeIntervalSince1970.bitPattern), String(usedPercent.bitPattern)]
        return values.map { String($0.utf8.count) + ":" + $0 }.joined(separator: "|")
    }

    private func sameReading(as other: Self) -> Bool {
        windowID == other.windowID && observedAt == other.observedAt && usedPercent == other.usedPercent
            && windowDurationMins == other.windowDurationMins && resetDate == other.resetDate
            && planType == other.planType && source == other.source
    }

    static func validAccountKey(_ key: String?) -> Bool {
        guard let key, key.utf8.count == 64 else { return false }
        return key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    fileprivate static func validIdentifier(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0)
        }
    }
    fileprivate static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (0...4_102_444_800).contains(date.timeIntervalSince1970)
    }
    fileprivate var valid: Bool {
        Self.validIdentifier(windowID.bucketID, limit: 80) && Self.validDate(observedAt)
            && usedPercent.isFinite && (0...100).contains(usedPercent)
            && (windowDurationMins.map { (1...525_600).contains($0) } ?? true)
            && (resetDate.map(Self.validDate) ?? true)
            && (planType.map { Self.validIdentifier($0, limit: 64) } ?? true)
            && Self.validIdentifier(source, limit: 48)
            && (segmentID.map { !$0.isEmpty && $0.utf8.count <= 512 && $0.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58,95,124].contains($0)
            } } ?? true)
    }
    fileprivate func startsNewSegment(after previous: Self) -> Bool {
        windowID != previous.windowID || resetDate != previous.resetDate
            || windowDurationMins != previous.windowDurationMins || planType != previous.planType || source != previous.source
            || observedAt <= previous.observedAt || observedAt.timeIntervalSince(previous.observedAt) > 900
            || usedPercent < previous.usedPercent - 0.01
            || (segmentID != nil && previous.segmentID != nil && segmentID != previous.segmentID)
    }
}

struct UsageForecastObservationSegment: Equatable, Identifiable {
    let id: String
    var observations: [UsageForecastObservation]
}

enum UsageForecastState: Equatable { case learning, ready, quiet, stale, waiting, unavailable, exhausted }

struct UsageForecastWindow: Equatable, Identifiable {
    let windowID: UsageForecastWindowID
    let windowDurationMins: Int?
    let remainingPercent: Double
    let resetDate: Date?
    let hoursUntilReset: Double?
    let safePercentPerHour: Double?
    let observedPercentPerHour: Double?
    let observedRateLower: Double?
    let observedRateUpper: Double?
    let exhaustionDate: Date?
    let reachesReset: Bool?
    let remainingAtReset: Double?
    let state: UsageForecastState
    let sampleCount: Int
    let coverage: Double
    let observations: [UsageForecastObservation]
    var historicalObservations:[UsageForecastObservation]=[]
    var provisionalPercentPerHour:Double?=nil
    var id: String { windowID.id }
    var safePercentPerDay: Double? { safePercentPerHour.map { $0 * 24 } }
}

struct UsageForecastScenarioWindow: Equatable, Identifiable {
    let windowID: UsageForecastWindowID
    let effectiveResetDate: Date?
    let safePercentPerHour: Double?
    let remainingAtExtraReset: Double?
    let exhaustionDate: Date?
    let relevant: Bool
    var id: String { windowID.id }
    var safePercentPerDay: Double? { safePercentPerHour.map { $0 * 24 } }
}

struct UsageForecastScenario: Equatable {
    let date: Date
    let windows: [UsageForecastScenarioWindow]
}

struct UsageForecastSnapshot: Equatable {
    static let freshness: TimeInterval = 300
    let windows: [UsageForecastWindow]
    let limitingWindow: UsageForecastWindow?
    let scenario: UsageForecastScenario?

    init(usage: UsageResponse?, observations: [UsageForecastObservation], updated: Date?, now: Date,
         extraResetDate: Date? = nil) {
        let fresh = updated.map { UsageForecastObservation.validDate($0) && $0 <= now.addingTimeInterval(60)
            && now.timeIntervalSince($0) <= Self.freshness } ?? false
        let current = usage.map { Self.currentReadings($0, now: now) } ?? []
        windows = current.map { reading in
            let matching = observations.filter { $0.windowID == reading.windowID }
            return Self.forecast(reading, history: matching, updated: updated, now: now, fresh: fresh)
        }
        limitingWindow = windows.filter { ($0.state == .ready || $0.state == .exhausted) && $0.exhaustionDate != nil }
            .min { ($0.exhaustionDate ?? .distantFuture) < ($1.exhaustionDate ?? .distantFuture) }
        if let extraResetDate, UsageForecastObservation.validDate(extraResetDate), extraResetDate > now,
           extraResetDate.timeIntervalSince(now) <= 28 * 86_400 {
            scenario = UsageForecastScenario(date: extraResetDate, windows: windows.map { window in
                guard fresh, let normal = window.resetDate, normal > now else {
                    return UsageForecastScenarioWindow(windowID: window.windowID, effectiveResetDate: nil,
                        safePercentPerHour: nil, remainingAtExtraReset: nil, exhaustionDate: nil, relevant: false)
                }
                let relevant = extraResetDate < normal
                let effective = min(normal, extraResetDate)
                let hours = effective.timeIntervalSince(now) / 3_600
                let projection = relevant ? window.observedPercentPerHour.map {
                    max(0, window.remainingPercent - $0 * hours)
                } : nil
                return UsageForecastScenarioWindow(windowID: window.windowID, effectiveResetDate: effective,
                    safePercentPerHour: window.remainingPercent / hours, remainingAtExtraReset: projection,
                    exhaustionDate: window.exhaustionDate.flatMap { $0 < effective ? $0 : nil }, relevant: relevant)
            })
        } else { scenario = nil }
    }

    private static func currentReadings(_ usage: UsageResponse, now: Date) -> [UsageForecastObservation] {
        // A synthetic gate only reuses the normalized sanitizer; no identity is
        // inferred from usage, and this value is never retained or persisted.
        UsageForecastObservation.sanitized(usage: usage, accountKey: String(repeating: "0", count: 64), at: now)
    }

    private static func forecast(_ current: UsageForecastObservation, history: [UsageForecastObservation],
                                 updated: Date?, now: Date, fresh: Bool) -> UsageForecastWindow {
        let remaining = 100 - current.usedPercent
        let reset = current.resetDate
        let hours = reset.flatMap { $0 > now ? $0.timeIntervalSince(now) / 3_600 : nil }
        let safe = fresh ? hours.map { remaining / $0 } : nil
        let minimumSpan: TimeInterval = (current.windowDurationMins ?? 1_440) >= 1_440 ? 21_600 : 3_600
        let retained = UsageForecastObservation.merged(existing: history, incoming: [], at: now)
        var segment = UsageForecastObservation.segments(retained, at: now).last?.observations ?? []
        if let last = segment.last, last.resetDate != reset || last.planType != current.planType
            || last.windowDurationMins != current.windowDurationMins
            || abs(last.usedPercent - current.usedPercent) > 0.01 { segment = [] }
        // A saturated quota cannot reveal demand while waiting. Keep the first
        // observed exhaustion endpoint and use only a still-fresh preceding
        // pace; a long plateau at 100% must not look like slower consumption.
        if remaining == 0, let exhausted = segment.firstIndex(where: { $0.usedPercent == 100 }) {
            segment = Array(segment[...exhausted])
        }
        let rateEnd = remaining == 0 ? min(segment.last?.observedAt ?? now, now) : now
        let rateCutoff = rateEnd.addingTimeInterval(-minimumSpan)
        if let index = segment.firstIndex(where: { $0.observedAt >= rateCutoff }) {
            let start = segment[index].observedAt == rateCutoff ? index : max(0, index - 1)
            segment = Array(segment[start...])
        } else { segment = [] }
        var state: UsageForecastState = .learning
        var rate: Double?, lower: Double?, upper: Double?, depletion: Date?, reaches: Bool?, projected: Double?
        let bins = Set(segment.map { Int64(floor($0.observedAt.timeIntervalSince1970 / 300)) }).count
        let span = (segment.last?.observedAt.timeIntervalSince(segment.first?.observedAt ?? now)) ?? 0
        var covered: TimeInterval = 0, movement = 0.0, blockRates = [Double]()
        for pair in zip(segment, segment.dropFirst()) {
            let elapsed = pair.1.observedAt.timeIntervalSince(pair.0.observedAt)
            if elapsed > 0 && elapsed <= 600 {
                let delta = max(0, pair.1.usedPercent - pair.0.usedPercent)
                covered += elapsed; movement += delta; blockRates.append(delta * 3_600 / elapsed)
            }
        }
        let coverage = span > 0 ? min(1, covered / span) : 0
        var supportedRate: Double?, supportedLower: Double?, supportedUpper: Double?
        let supported = segment.last.map { now.timeIntervalSince($0.observedAt) <= freshness } == true
            && bins >= 6 && span >= minimumSpan && coverage >= 0.8
        if supported, movement >= 2, covered > 0 {
            let measured = movement * 3_600 / covered
            if measured.isFinite && measured > 0 {
                supportedRate = measured
                let sorted = blockRates.sorted()
                if !sorted.isEmpty {
                    supportedLower = min(measured, sorted[(sorted.count - 1) / 5])
                    supportedUpper = max(measured, sorted[(sorted.count - 1) * 4 / 5])
                }
            }
        }
        if !fresh { state = updated == nil ? .unavailable : .stale }
        else if let reset, reset <= now { state = .waiting }
        else if remaining == 0 {
            state = .exhausted; depletion = now; reaches = false; projected = 0
            // Zero remaining is factual. A sufficiently observed current-cycle
            // pace can additionally model a conditional resumption after an
            // extra reset, without manufacturing a rate on cold start.
            if reset != nil { rate = supportedRate; lower = supportedLower; upper = supportedUpper }
        }
        else if reset == nil { state = .unavailable }
        else if hours == nil { state = .waiting }
        else if supported {
            if movement < 2 { state = .quiet }
            else if let measured = supportedRate {
                rate = measured; lower = supportedLower; upper = supportedUpper; state = .ready
                let seconds = remaining * 3_600 / measured
                if seconds.isFinite, seconds >= 0, let reset {
                    let date = now.addingTimeInterval(seconds)
                    reaches = date >= reset
                    if date < reset { depletion = date }
                    projected = max(0, remaining - measured * (hours ?? 0))
                }
            }
        }
        var result=UsageForecastWindow(windowID: current.windowID, windowDurationMins: current.windowDurationMins,
            remainingPercent: remaining, resetDate: reset, hoursUntilReset: hours, safePercentPerHour: safe,
            observedPercentPerHour: rate, observedRateLower: lower, observedRateUpper: upper,
            exhaustionDate: depletion, reachesReset: reaches, remainingAtReset: projected, state: state,
            sampleCount: bins, coverage: coverage, observations: segment)
        result.historicalObservations=retained.filter {$0.windowDurationMins == current.windowDurationMins && $0.planType == current.planType && $0.source == current.source}
        if fresh,rate == nil,bins >= 6,span >= 3600,coverage >= 0.8,movement >= 1,covered > 0 {
            result.provisionalPercentPerHour=movement*3600/covered
        }
        return result
    }
}

enum UsageForecastCurveKind: Equatable { case observed, consuming, waiting, resetJump }

struct UsageForecastCurvePoint: Equatable, Identifiable {
    let id: String
    let date: Date
    let remaining: Double
}

struct UsageForecastCurveSegment: Equatable, Identifiable {
    let id: String
    let kind: UsageForecastCurveKind
    let points: [UsageForecastCurvePoint]
}

struct UsageForecastCurveSample: Equatable {
    let date: Date
    let observedRemaining: Double?
    let baselineRemaining: Double?
    let scenarioRemaining: Double?
}

// This comparison has one frozen percentage-point pace. Neither tokens nor a
// predicted extra reset can change that observed pace or the actual quota.
enum UsageForecastProjectionBasis: String {case measured,provisional,budget,unavailable}

struct UsageForecastComparison: Equatable {
    let projectionBasis:UsageForecastProjectionBasis
    let historySegments: [UsageForecastCurveSegment]
    let baselineSegments: [UsageForecastCurveSegment]
    let scenarioSegments: [UsageForecastCurveSegment]
    let domain: ClosedRange<Date>
    let axisDates: [Date]
    let regularResetDate: Date?
    let extraResetDate: Date?
    let scenarioRelevant: Bool
    let observedPercentPerHour: Double?
    let baselineExhaustionDate: Date?
    let scenarioExhaustionDate: Date?
    let baselineWaitingIntervals: [DateInterval]
    let scenarioWaitingIntervals: [DateInterval]
    let baselineWaitingSeconds: Double?
    let scenarioWaitingSeconds: Double?
    let savedWaitingSeconds: Double?
    let normalSafePercentPerHour: Double?
    let preExtraSafePercentPerHour: Double?
    let remainingAtExtraReset: Double?
    let state: UsageForecastState

    var timeDomain: ClosedRange<Date> { domain }
    var normalResetDate: Date? { regularResetDate }
    var baselineWaitInterval: DateInterval? { baselineWaitingIntervals.first }
    var savedHours: Double? { savedWaitingSeconds.map { $0 / 3_600 } }

    init(window: UsageForecastWindow, now: Date, scenarioEnabled: Bool = false,
         extraResetDate requestedExtra: Date? = nil, assumesFullReset: Bool = false,
         quotaError: Bool = false,allowBudgetReference:Bool = false) {
        let validNow = UsageForecastObservation.validDate(now)
        let validRemaining = window.remainingPercent.isFinite && (0...100).contains(window.remainingPercent)
        let current = validNow ? now : Date(timeIntervalSince1970: 0)
        let freshState = [.ready, .learning, .quiet, .exhausted].contains(window.state)
        let supportedCurrent = validNow && validRemaining && freshState && !quotaError
        let reset = window.resetDate.flatMap { UsageForecastObservation.validDate($0) ? $0 : nil }
        let futureReset = supportedCurrent ? reset.flatMap { $0 > current ? $0 : nil } : nil
        regularResetDate = reset
        state = quotaError || !validNow || !validRemaining ? .unavailable : window.state
        let measured = supportedCurrent && (window.state == .ready || window.state == .exhausted)
            ? window.observedPercentPerHour.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } : nil
        let preliminary=allowBudgetReference && supportedCurrent ? window.provisionalPercentPerHour.flatMap {$0.isFinite && $0 > 0 ? $0 : nil} : nil
        let budget=allowBudgetReference && supportedCurrent && window.remainingPercent > 0 ? futureReset.map {window.remainingPercent*3600/$0.timeIntervalSince(current)} : nil
        let rate=measured ?? preliminary ?? budget
        projectionBasis=measured != nil ? .measured : preliminary != nil ? .provisional : budget != nil ? .budget : .unavailable
        observedPercentPerHour = futureReset == nil ? nil : measured
        let acceptedExtra = requestedExtra.flatMap { date -> Date? in
            UsageForecastObservation.validDate(date) && validNow && date > current
                && date.timeIntervalSince(current) <= 28 * 86_400 ? date : nil
        }
        extraResetDate = scenarioEnabled ? acceptedExtra : nil
        let relevant = scenarioEnabled && assumesFullReset && acceptedExtra.map { extra in
            futureReset.map { extra < $0 } ?? false
        } == true
        scenarioRelevant = relevant
        normalSafePercentPerHour = futureReset.map { window.remainingPercent * 3_600 / $0.timeIntervalSince(current) }
        preExtraSafePercentPerHour = relevant ? acceptedExtra.map {
            window.remainingPercent * 3_600 / $0.timeIntervalSince(current)
        } : nil
        remainingAtExtraReset = relevant ? acceptedExtra.flatMap { extra in
            if window.remainingPercent == 0 { return 0 }
            return rate.map { max(0, window.remainingPercent - $0 * extra.timeIntervalSince(current) / 3_600) }
        } : nil

        let historical = validNow ? UsageForecastObservation.segments(window.historicalObservations.isEmpty ? window.observations : window.historicalObservations, at: current).enumerated().map { ordinal,segment in
            UsageForecastCurveSegment(id: "history." + segment.id + "." + String(ordinal), kind: .observed,
                points: segment.observations.filter { $0.observedAt <= current }.enumerated().map { index, reading in
                    UsageForecastCurvePoint(id: "history." + segment.id + "." + String(ordinal) + "." + String(index),
                        date: reading.observedAt, remaining: 100 - reading.usedPercent)
                })
        }.filter { !$0.points.isEmpty } : []
        let first = historical.flatMap(\.points).map(\.date).min() ?? current
        let end = futureReset ?? current
        domain = min(first, current)...max(end, current)
        axisDates = Self.ticks(domain)
        if historical.isEmpty, supportedCurrent {
            historySegments = [.init(id: "history.current", kind: .observed,
                points: [.init(id: "history.current.0", date: current, remaining: window.remainingPercent)])]
        } else { historySegments = historical }

        var baseline = [UsageForecastCurveSegment](), scenario = [UsageForecastCurveSegment]()
        var baselineWaits = [DateInterval](), scenarioWaits = [DateInterval]()
        var baselineZero: Date?, scenarioZero: Date?
        var baselineSeconds: Double?, scenarioSeconds: Double?, saved: Double?
        if let end = futureReset {
            if let rate {
                let normal = Self.path(id: "baseline", from: current, remaining: window.remainingPercent,
                    rate: rate, to: end, ticks: axisDates)
                baseline = normal.segments; baselineWaits = normal.waiting
                baselineZero = normal.exhaustion; baselineSeconds = normal.waiting.reduce(0) { $0 + $1.duration }
                if relevant, let extra = acceptedExtra {
                    let before = Self.path(id: "scenario.before", from: current, remaining: window.remainingPercent,
                        rate: rate, to: extra, ticks: axisDates)
                    let priorRemaining = max(0, window.remainingPercent - rate * extra.timeIntervalSince(current) / 3_600)
                    let jump = UsageForecastCurveSegment(id: "scenario.reset", kind: .resetJump, points: [
                        .init(id: "scenario.reset.before", date: extra, remaining: priorRemaining),
                        .init(id: "scenario.reset.after", date: extra, remaining: 100)
                    ])
                    let after = Self.path(id: "scenario.after", from: extra, remaining: 100,
                        rate: rate, to: end, ticks: axisDates)
                    scenario = before.segments + [jump] + after.segments
                    scenarioWaits = before.waiting + after.waiting
                    scenarioZero = before.exhaustion ?? after.exhaustion
                    scenarioSeconds = scenarioWaits.reduce(0) { $0 + $1.duration }
                    saved = max(0, (baselineSeconds ?? 0) - (scenarioSeconds ?? 0))
                }
            } else if window.remainingPercent == 0 {
                // Waiting is already observed even when a post-reset slope is
                // unknown. Do not turn that fact into a guessed scenario saving.
                baseline = [Self.line(id: "baseline.waiting", kind: .waiting, dates: [current, end]) { _ in 0 }]
                baselineWaits = [DateInterval(start: current, end: end)]
                baselineZero = current; baselineSeconds = end.timeIntervalSince(current)
            }
        }
        baselineSegments = baseline; scenarioSegments = scenario
        baselineWaitingIntervals = baselineWaits; scenarioWaitingIntervals = scenarioWaits
        baselineExhaustionDate = baselineZero; scenarioExhaustionDate = scenarioZero
        baselineWaitingSeconds = baselineSeconds; scenarioWaitingSeconds = scenarioSeconds
        savedWaitingSeconds = saved
    }

    func sample(at requested: Date) -> UsageForecastCurveSample? {
        guard requested.timeIntervalSince1970.isFinite else { return nil }
        let date = min(max(requested, domain.lowerBound), domain.upperBound)
        return .init(date: date, observedRemaining: Self.value(at: date, in: historySegments),
            baselineRemaining: Self.value(at: date, in: baselineSegments),
            scenarioRemaining: Self.value(at: date, in: scenarioSegments))
    }

    private static func value(at date: Date, in segments: [UsageForecastCurveSegment]) -> Double? {
        // Later segments win at a discontinuity, so the event itself returns
        // the explicitly assumed post-reset value rather than its old quota.
        for segment in segments.reversed() {
            guard let first = segment.points.first, let last = segment.points.last,
                  first.date <= date, date <= last.date else { continue }
            if date == last.date { return last.remaining }
            for pair in zip(segment.points, segment.points.dropFirst()) where pair.0.date <= date && date <= pair.1.date {
                let span = pair.1.date.timeIntervalSince(pair.0.date)
                if span == 0 { return pair.1.remaining }
                let fraction = date.timeIntervalSince(pair.0.date) / span
                return pair.0.remaining + (pair.1.remaining - pair.0.remaining) * fraction
            }
            if date == first.date { return first.remaining }
        }
        return nil
    }

    private static func path(id: String, from start: Date, remaining: Double, rate: Double, to end: Date,
                             ticks: [Date]) -> (segments: [UsageForecastCurveSegment], waiting: [DateInterval], exhaustion: Date?) {
        let duration = remaining * 3_600 / rate
        let exhaustion = duration.isFinite ? start.addingTimeInterval(duration) : .distantFuture
        let stop = min(exhaustion, end)
        var segments = [UsageForecastCurveSegment](), waiting = [DateInterval]()
        if remaining > 0 {
            let dates = Array(Set([start, stop] + ticks.filter { $0 > start && $0 < stop })).sorted()
            segments.append(line(id: id + ".consuming", kind: .consuming, dates: dates) { date in
                max(0, min(100, remaining - rate * date.timeIntervalSince(start) / 3_600))
            })
        }
        if exhaustion < end {
            let zero = max(start, exhaustion)
            segments.append(line(id: id + ".waiting", kind: .waiting, dates: [zero, end]) { _ in 0 })
            waiting.append(DateInterval(start: zero, end: end))
        }
        return (segments, waiting, exhaustion <= end ? exhaustion : nil)
    }

    private static func line(id: String, kind: UsageForecastCurveKind, dates: [Date],
                             value: (Date) -> Double) -> UsageForecastCurveSegment {
        .init(id: id, kind: kind, points: dates.enumerated().map { index, date in
            .init(id: id + "." + String(index), date: date, remaining: value(date))
        })
    }

    private static func ticks(_ domain: ClosedRange<Date>) -> [Date] {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return [domain.lowerBound] }
        let intervals: [TimeInterval] = [900, 1_800, 3_600, 7_200, 10_800, 21_600, 43_200,
            86_400, 172_800, 604_800, 1_209_600, 2_419_200]
        let step = intervals.first { $0 >= span / 8 } ?? span / 8
        let count = min(8, Int(floor(span / step)))
        let values = (0...count).map { domain.lowerBound.addingTimeInterval(Double($0) * step) }
        return Array(Set(values + [domain.upperBound])).sorted()
    }
}

enum UsageForecastCacheFailure: Error { case unsafePath, invalidData, tooLarge, staleGeneration }

// Cache methods are serialized and contain no suspension points. The caller
// captures an epoch before its existing request so a clear rejects late results.
actor UsageForecastCache {
    static let maximumBytes = 2 * 1_024 * 1_024
    static let shared = UsageForecastCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.duoduocat.codexbuddy/UsageForecast", isDirectory: true))
    let directory: URL
    private struct Window: Codable { let id: UsageForecastWindowID; var samples: [UsageForecastObservation] }
    private struct Account: Codable { let key: String; var lastSeen: Date; var windows: [Window] }
    private struct Document: Codable { let schemaVersion: Int; let accounts: [Account] }
    private var accounts = [Account]()
    private var loaded = false
    private var failedLoad = false
    private var epoch: UInt64 = 0
    private let filename = "history.json"
    // Retain the supplied physical path. Foundation standardization can turn
    // an existing /private/tmp path into its /tmp symlink alias on macOS.
    init(directory: URL) { self.directory = directory }

    func generationToken() -> UInt64 { epoch }
    func observations(accountKey: String?, at: Date = Date()) -> [UsageForecastObservation] {
        guard UsageForecastObservation.validAccountKey(accountKey), UsageForecastObservation.validDate(at),
              (try? load(at: at)) != nil else { return [] }
        prune(at: at)
        return accounts.first(where: { $0.key == accountKey })?.windows.flatMap(\.samples) ?? []
    }
    func record(usage: UsageResponse, accountKey: String?, at: Date,
                source: String = "native-wham", expectedGeneration: UInt64? = nil) throws -> [UsageForecastObservation] {
        try Task.checkCancellation()
        if let expectedGeneration, expectedGeneration != epoch { throw UsageForecastCacheFailure.staleGeneration }
        let samples = UsageForecastObservation.sanitized(usage: usage, accountKey: accountKey, at: at, source: source)
        guard let accountKey, !samples.isEmpty else { return [] }
        try load(at: at); prune(at: at)
        if !accounts.contains(where: { $0.key == accountKey }) { accounts.append(Account(key: accountKey, lastSeen: at, windows: [])) }
        guard let index = accounts.firstIndex(where: { $0.key == accountKey }) else { return [] }
        accounts[index].lastSeen = at
        for sample in samples {
            if !accounts[index].windows.contains(where: { $0.id == sample.windowID }) {
                accounts[index].windows.append(Window(id: sample.windowID, samples: []))
            }
            guard let window = accounts[index].windows.firstIndex(where: { $0.id == sample.windowID }) else { continue }
            UsageForecastObservation.append(sample, to: &accounts[index].windows[window].samples)
        }
        prune(at: at, preserving: accountKey)
        let data = try encodedData(preserving: accountKey)
        try write(data)
        return accounts.first(where: { $0.key == accountKey })?.windows.flatMap(\.samples) ?? []
    }
    func clear() throws {
        epoch &+= 1; accounts = []; loaded = true; failedLoad = false
        guard let fd = try directoryDescriptor(create: false) else { return }
        defer { Darwin.close(fd) }
        try checkLeaf(fd, enforceSize: false)
        if unlinkat(fd, filename, 0) != 0 && errno != ENOENT { throw UsageForecastCacheFailure.unsafePath }
    }
    func byteCount() throws -> Int64 {
        guard let fd = try directoryDescriptor(create: false) else { return 0 }
        defer { Darwin.close(fd) }
        var info = stat()
        if fstatat(fd, filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return 0 }; throw UsageForecastCacheFailure.unsafePath
        }
        try checkInfo(info)
        return Int64(info.st_size)
    }

    private func load(at: Date) throws {
        if loaded { if failedLoad { throw UsageForecastCacheFailure.invalidData }; return }
        loaded = true
        do {
            guard let data = try read() else { return }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.schemaVersion == 1, document.accounts.count <= 4,
                  Set(document.accounts.map(\.key)).count == document.accounts.count else { throw UsageForecastCacheFailure.invalidData }
            for account in document.accounts {
                guard UsageForecastObservation.validAccountKey(account.key), UsageForecastObservation.validDate(account.lastSeen),
                      account.lastSeen <= at.addingTimeInterval(60), account.windows.count <= 8,
                      Set(account.windows.map(\.id)).count == account.windows.count else { throw UsageForecastCacheFailure.invalidData }
                for window in account.windows {
                    guard UsageForecastObservation.validIdentifier(window.id.bucketID, limit: 80), window.samples.count <= UsageForecastObservation.maximumSamplesPerWindow,
                          window.samples.allSatisfy({ $0.valid && $0.windowID == window.id && $0.observedAt <= at.addingTimeInterval(60) })
                    else { throw UsageForecastCacheFailure.invalidData }
                }
            }
            accounts = document.accounts; prune(at: at)
        } catch { accounts = []; failedLoad = true; throw error }
    }
    private func prune(at: Date, preserving key: String? = nil) {
        let cutoff = at.addingTimeInterval(-28 * 86_400)
        accounts = accounts.filter { $0.lastSeen >= cutoff && $0.lastSeen <= at.addingTimeInterval(60) }
        for account in accounts.indices {
            for window in accounts[account].windows.indices {
                accounts[account].windows[window].samples = UsageForecastObservation.bounded(accounts[account].windows[window].samples
                    .filter { $0.observedAt >= cutoff && $0.observedAt <= at.addingTimeInterval(60) },limit:UsageForecastObservation.maximumSamplesPerWindow)
            }
            accounts[account].windows = Array(accounts[account].windows.filter { !$0.samples.isEmpty }
                .sorted { ($0.samples.last?.observedAt ?? .distantPast) > ($1.samples.last?.observedAt ?? .distantPast) }.prefix(8))
        }
        accounts = Array(accounts.filter { !$0.windows.isEmpty }.sorted {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            if ($0.key == key) != ($1.key == key) { return $0.key == key }
            return $0.key < $1.key
        }.prefix(4))
    }

    private func encodedData(preserving key: String) throws -> Data {
        var data = try JSONEncoder().encode(Document(schemaVersion: 1, accounts: accounts))
        while data.count > Self.maximumBytes {
            if let oldest = accounts.indices.filter({ accounts[$0].key != key }).min(by: { accounts[$0].lastSeen < accounts[$1].lastSeen }) {
                accounts.remove(at: oldest)
            } else if let account = accounts.firstIndex(where: { $0.key == key }),
                      let window = accounts[account].windows.indices.filter({ accounts[account].windows[$0].samples.count > 1 })
                        .min(by: { accounts[account].windows[$0].samples[0].observedAt < accounts[account].windows[$1].samples[0].observedAt }) {
                let count = max(1, accounts[account].windows[window].samples.count / 4)
                accounts[account].windows[window].samples=UsageForecastObservation.bounded(accounts[account].windows[window].samples,limit:accounts[account].windows[window].samples.count-count)
            } else { throw UsageForecastCacheFailure.tooLarge }
            data = try JSONEncoder().encode(Document(schemaVersion: 1, accounts: accounts))
        }
        return data
    }

    // Walk each path component with no-follow directory descriptors, so neither
    // directory symlinks nor leaf links can redirect a cache operation.
    private func directoryDescriptor(create: Bool) throws -> Int32? {
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.path != "/",
              directory.pathComponents.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw UsageForecastCacheFailure.unsafePath }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UsageForecastCacheFailure.unsafePath }
        for component in directory.pathComponents.dropFirst() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next >= 0 { Darwin.close(fd); fd = next; continue }
            if errno == ENOENT {
                if !create { Darwin.close(fd); return nil }
                if mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { Darwin.close(fd); throw UsageForecastCacheFailure.unsafePath }
                let made = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard made >= 0 else { Darwin.close(fd); throw UsageForecastCacheFailure.unsafePath }
                Darwin.close(fd); fd = made
            } else { Darwin.close(fd); throw UsageForecastCacheFailure.unsafePath }
        }
        return fd
    }
    private func checkInfo(_ info: stat, enforceSize: Bool = true) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw UsageForecastCacheFailure.unsafePath }
        guard info.st_size >= 0, !enforceSize || info.st_size <= Self.maximumBytes else { throw UsageForecastCacheFailure.tooLarge }
    }
    private func checkLeaf(_ fd: Int32, enforceSize: Bool = true) throws {
        var info = stat()
        if fstatat(fd, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 { try checkInfo(info, enforceSize: enforceSize) }
        else if errno != ENOENT { throw UsageForecastCacheFailure.unsafePath }
    }
    private func read() throws -> Data? {
        guard let directoryFD = try directoryDescriptor(create: false) else { return nil }
        defer { Darwin.close(directoryFD) }
        let fd = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw UsageForecastCacheFailure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw UsageForecastCacheFailure.unsafePath }
        try checkInfo(info)
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes, data.count == info.st_size else { throw UsageForecastCacheFailure.tooLarge }
        return data
    }
    private func write(_ data: Data) throws {
        guard data.count <= Self.maximumBytes, let directoryFD = try directoryDescriptor(create: true)
        else { throw UsageForecastCacheFailure.tooLarge }
        defer { Darwin.close(directoryFD) }
        try checkLeaf(directoryFD)
        let candidate = ".history-" + UUID().uuidString + ".tmp"
        let fd = openat(directoryFD, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UsageForecastCacheFailure.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(directoryFD, candidate, 0) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        try checkLeaf(directoryFD)
        guard renameat(directoryFD, candidate, directoryFD, filename) == 0 else { throw UsageForecastCacheFailure.unsafePath }
    }
}
