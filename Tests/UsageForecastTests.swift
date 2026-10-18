import Foundation
import Darwin

@main struct UsageForecastTests {
    static let key = String(repeating: "a", count: 64)

    static func main() async throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!
        planningAndHistory(now:now)
        historyHandoff(now:now)
        math(now: now)
        comparison(now: now)
        segmentation(now: now)
        closedSegmentRetention(now: now)
        binningAndRecentPace(now: now)
        sanitizer(now: now)
        try await cache(now: now)
        print("Usage forecast tests passed: baseline/target-date budget comparison, explicit reset discontinuity, saturation/wait/resume/saved hours, honest missing-rate states, isolated latest-segment fit, retained bounded closed segments, independent quota windows, recent horizons, account isolation, corrupt/oversize/link refusal, serial clear epoch")
    }

    static func planningAndHistory(now:Date) {
        let reset=now.addingTimeInterval(18*3600)
        let cold=UsageForecastSnapshot(usage:response(used:70,reset:reset),observations:[],updated:now,now:now).windows[0]
        let planned=UsageForecastComparison(window:cold,now:now,scenarioEnabled:true,extraResetDate:now.addingTimeInterval(9*3600),assumesFullReset:true,allowBudgetReference:true)
        precondition(planned.projectionBasis == .budget && !planned.baselineSegments.isEmpty && !planned.scenarioSegments.isEmpty)
        precondition(planned.observedPercentPerHour == nil,"A budget is not a measured consumption rate")
        precondition(planned.scenarioSegments.contains {$0.kind == .resetJump && $0.points.last?.remaining == 100})
        let raw=readings(used:70,start:0,span:24*3600,now:now,reset:reset)
        let history=UsageForecastSnapshot(usage:response(used:70,reset:reset),observations:raw,updated:now,now:now).windows[0]
        precondition(history.historicalObservations.first?.usedPercent == 0 && history.historicalObservations.count > history.observations.count,"Display full recorded history separately from the recent fitting horizon")
        let plot=UsageForecastComparison(window:history,now:now,allowBudgetReference:true)
        precondition(plot.historySegments.flatMap(\.points).contains {$0.remaining == 100})
        let stale=UsageForecastComparison(window:cold,now:now.addingTimeInterval(400),quotaError:true,allowBudgetReference:true)
        precondition(stale.baselineSegments.isEmpty && stale.projectionBasis == .unavailable)
    }
    static func historyHandoff(now:Date) {
        let reset=now.addingTimeInterval(18*3600),observed=now.addingTimeInterval(-180)
        let raw=readings(used:70,start:70,span:6*3600,now:observed,reset:reset)
        let usage=response(used:70,reset:reset)
        let window=UsageForecastSnapshot(usage:usage,observations:raw,updated:observed,now:now).windows[0]
        let plot=UsageForecastComparison(window:window,now:now,allowBudgetReference:true)
        precondition(plot.historySegments.last?.points.last?.date == observed && plot.historyHandoff?.points.last?.date == now)
        precondition(plot.historyHandoff?.points.first?.remaining == 30 && plot.baselineSegments.first?.points.first?.remaining == 30)
        let sample=plot.sample(at:now.addingTimeInterval(-90))!
        precondition(sample.observedRemaining == nil && sample.carriedRemaining == 30,
                     "The handoff is explicitly last-known, not an invented observation")
        precondition(window.historicalObservations.last?.observedAt == observed && raw.last?.observedAt == observed)
        let stale=UsageForecastComparison(window:UsageForecastSnapshot(usage:usage,observations:raw,updated:observed,now:now.addingTimeInterval(200)).windows[0],now:now.addingTimeInterval(200),allowBudgetReference:true)
        precondition(stale.historyHandoff == nil && stale.baselineSegments.isEmpty)
        let resetChanged=UsageForecastSnapshot(usage:response(used:70,reset:reset.addingTimeInterval(3600)),observations:raw,updated:now,now:now).windows[0]
        precondition(UsageForecastComparison(window:resetChanged,now:now,allowBudgetReference:true).historyHandoff == nil)
        precondition(UsageForecastComparison(window:window,now:now,quotaError:true,allowBudgetReference:true).historyHandoff == nil)
    }
    static func response(used: Double = 70, duration: Int? = 10_080, reset: Date?, plan: String? = "plus",
                         secondary: LimitWindow? = nil, bucket: String = "codex") -> UsageResponse {
        let entry = LimitBucket(limitId: bucket, limitName: "Synthetic display name", primary:
            LimitWindow(usedPercent: used, windowDurationMins: duration, resetsAt: reset?.timeIntervalSince1970),
            secondary: secondary, planType: plan)
        return UsageResponse(rateLimits: entry, rateLimitsByLimitId: [bucket: entry], rateLimitResetCredits: .init(availableCount: 2))
    }
    static func readings(used: Double, start: Double, span: TimeInterval, now: Date,
                         duration: Int? = 10_080, reset: Date, interval: TimeInterval = 300,
                         source: String = "native-wham", plan: String? = "plus") -> [UsageForecastObservation] {
        let count = Int(span / interval)
        return (0...count).map { index in
            UsageForecastObservation(windowID: .init(bucketID: "codex", role: .primary),
                observedAt: now.addingTimeInterval(Double(index - count) * interval),
                usedPercent: start + (used - start) * Double(index) / Double(count),
                windowDurationMins: duration, resetDate: reset, planType: plan, source: source)
        }
    }
    static func near(_ first: Double?, _ second: Double, tolerance: Double = 0.000_001) {
        precondition(first.map { abs($0 - second) < tolerance } == true)
    }
    static func math(now: Date) {
        let reset = now.addingTimeInterval(18 * 3_600)
        let usage = response(reset: reset)
        let cold = UsageForecastSnapshot(usage: usage, observations: [], updated: now, now: now).windows[0]
        precondition(cold.state == .learning && cold.remainingPercent == 30 && cold.exhaustionDate == nil)
        near(cold.safePercentPerHour, 30.0 / 18); near(cold.safePercentPerDay, 40)
        let observations = readings(used: 70, start: 58, span: 6 * 3_600, now: now, reset: reset)
        let forecast = UsageForecastSnapshot(usage: usage, observations: observations, updated: now, now: now)
        let window = forecast.windows[0]
        precondition(window.state == .ready && window.coverage == 1 && window.sampleCount >= 6)
        near(window.observedPercentPerHour, 2)
        near(window.exhaustionDate?.timeIntervalSince(now), 15 * 3_600)
        precondition(window.reachesReset == false && window.remainingAtReset == 0 && forecast.limitingWindow?.id == window.id)
        let hypothetical = UsageForecastSnapshot(usage: usage, observations: observations, updated: now, now: now,
            extraResetDate: now.addingTimeInterval(12 * 3_600))
        precondition(hypothetical.windows == forecast.windows, "An extra-reset assumption never changes actual quota or baseline")
        let scenario = hypothetical.scenario!.windows[0]
        near(scenario.safePercentPerHour, 2.5); near(scenario.remainingAtExtraReset, 6)
        precondition(scenario.relevant && scenario.effectiveResetDate == now.addingTimeInterval(12 * 3_600) && scenario.exhaustionDate == nil)
        let later = UsageForecastSnapshot(usage: usage, observations: observations, updated: now, now: now,
            extraResetDate: now.addingTimeInterval(24 * 3_600)).scenario!.windows[0]
        precondition(!later.relevant && later.effectiveResetDate == reset && later.remainingAtExtraReset == nil)
        for date in [now, now.addingTimeInterval(-1), now.addingTimeInterval(29 * 86_400)] {
            precondition(UsageForecastSnapshot(usage: usage, observations: observations, updated: now, now: now, extraResetDate: date).scenario == nil)
        }
        let quiet = UsageForecastSnapshot(usage: usage, observations: readings(used: 70, start: 70, span: 6 * 3_600,
            now: now, reset: reset), updated: now, now: now).windows[0]
        precondition(quiet.state == .quiet && quiet.observedPercentPerHour == nil && quiet.exhaustionDate == nil)
        let tiny = UsageForecastSnapshot(usage: usage, observations: readings(used: 70, start: 68.5, span: 6 * 3_600,
            now: now, reset: reset), updated: now, now: now).windows[0]
        precondition(tiny.state == .quiet && tiny.exhaustionDate == nil)
        let stale = UsageForecastSnapshot(usage: usage, observations: observations, updated: now.addingTimeInterval(-301), now: now).windows[0]
        precondition(stale.state == .stale && stale.safePercentPerHour == nil && stale.observedPercentPerHour == nil && stale.remainingPercent == 30)
        let unavailable = UsageForecastSnapshot(usage: usage, observations: observations, updated: nil, now: now).windows[0]
        precondition(unavailable.state == .unavailable && unavailable.safePercentPerHour == nil)
        let waiting = UsageForecastSnapshot(usage: response(reset: now.addingTimeInterval(-1)), observations: observations,
            updated: now, now: now).windows[0]
        precondition(waiting.state == .waiting && waiting.remainingPercent == 30 && waiting.safePercentPerHour == nil && waiting.exhaustionDate == nil)
        let noReset = UsageForecastSnapshot(usage: response(reset: nil), observations: observations, updated: now, now: now).windows[0]
        precondition(noReset.state == .unavailable && noReset.hoursUntilReset == nil && noReset.safePercentPerHour == nil)
        let exhausted = UsageForecastSnapshot(usage: response(used: 100, reset: reset), observations: [], updated: now, now: now)
        precondition(exhausted.windows[0].state == .exhausted && exhausted.windows[0].exhaustionDate == now)
        precondition(exhausted.windows[0].observedPercentPerHour == nil && exhausted.limitingWindow?.remainingPercent == 0)
        let passedZero = UsageForecastSnapshot(usage: response(used: 100, reset: now.addingTimeInterval(-60)),
            observations: [], updated: now.addingTimeInterval(-120), now: now).windows[0]
        precondition(passedZero.state == .waiting && passedZero.remainingPercent == 0 && passedZero.exhaustionDate == nil,
                     "Passing a reset boundary must wait for current-cycle evidence, not grant quota or claim an old exhaustion ETA")

        let short = LimitWindow(usedPercent: 94, windowDurationMins: 300, resetsAt: now.addingTimeInterval(2 * 3_600).timeIntervalSince1970)
        let multi = response(reset: reset, secondary: short)
        let demo = UsageForecastObservation.demo(usage: multi, now: now)
        let multiple = UsageForecastSnapshot(usage: multi, observations: demo, updated: now, now: now)
        precondition(multiple.windows.count == 2 && multiple.windows.map(\.remainingPercent) == [30, 6])
        precondition(multiple.limitingWindow?.windowID.role == .secondary)
        near(multiple.windows[1].exhaustionDate?.timeIntervalSince(now), 3_600)
        let shortCovered = UsageForecastSnapshot(usage: response(used: 30, duration: 300, reset: now.addingTimeInterval(2 * 3_600)),
            observations: readings(used: 30, start: 28, span: 3_600, now: now, duration: 300, reset: now.addingTimeInterval(2 * 3_600)),
            updated: now, now: now).windows[0]
        precondition(shortCovered.state == .ready && shortCovered.reachesReset == true && shortCovered.exhaustionDate == nil)
        near(shortCovered.remainingAtReset, 66)
    }

    static func segmentation(now: Date) {
        let reset = now.addingTimeInterval(18 * 3_600)
        let prior = readings(used: 69, start: 57, span: 6 * 3_600, now: now.addingTimeInterval(-300), reset: reset)
        for change in ["reset", "plan", "duration", "source", "drop", "reverse", "gap"] {
            let changedReset = change == "reset" ? reset.addingTimeInterval(1) : reset
            let plan = change == "plan" ? "pro" : "plus"
            let duration = change == "duration" ? 1_440 : 10_080
            let used = change == "drop" ? 20.0 : 70.0
            let timestamp = change == "reverse" ? now.addingTimeInterval(-600) : change == "gap" ? now.addingTimeInterval(1_000) : now
            let observation = UsageForecastObservation(windowID: .init(bucketID: "codex", role: .primary), observedAt: timestamp,
                usedPercent: used, windowDurationMins: duration, resetDate: changedReset, planType: plan,
                source: change == "source" ? "synthetic-v2" : "native-wham")
            let result = UsageForecastSnapshot(usage: response(used: used, duration: duration, reset: changedReset, plan: plan),
                observations: prior + [observation], updated: timestamp, now: timestamp).windows[0]
            precondition(result.state == .learning && result.observedPercentPerHour == nil && result.observations.count == 1,
                         "Reset/plan/source/duration/drop/time/gap changes must not reuse old estimates")
        }
        let sparse = readings(used: 70, start: 58, span: 6 * 3_600, now: now, reset: reset, interval: 900)
        let poor = UsageForecastSnapshot(usage: response(reset: reset), observations: sparse, updated: now, now: now).windows[0]
        precondition(poor.coverage < 0.8 && poor.state == .learning)
        let old = readings(used: 70, start: 58, span: 6 * 3_600, now: now.addingTimeInterval(-301), reset: reset)
        precondition(UsageForecastSnapshot(usage: response(reset: reset), observations: old, updated: now, now: now).windows[0].state == .learning)
    }

    static func comparison(now: Date) {
        let reset = now.addingTimeInterval(18 * 3_600)
        let usage = response(reset: reset)
        let observations = readings(used: 70, start: 58, span: 6 * 3_600, now: now, reset: reset)
        let window = UsageForecastSnapshot(usage: usage, observations: observations, updated: now, now: now).windows[0]
        let extra = now.addingTimeInterval(9 * 3_600)
        let baseline = UsageForecastComparison(window: window, now: now)
        let compared = UsageForecastComparison(window: window, now: now, scenarioEnabled: true,
            extraResetDate: extra, assumesFullReset: true)
        precondition(compared.baselineSegments == baseline.baselineSegments && compared.historySegments == baseline.historySegments,
                     "An enabled simulation must preserve the baseline and observed history")
        precondition(compared.timeDomain == now.addingTimeInterval(-6 * 3_600)...reset)
        precondition(compared.axisDates.count == 9 && compared.axisDates[1] == now.addingTimeInterval(-3 * 3_600))
        near(compared.observedPercentPerHour, 2)
        near(compared.normalSafePercentPerHour, 30.0 / 18)
        near(compared.preExtraSafePercentPerHour, 30.0 / 9)
        near(compared.remainingAtExtraReset, 0)
        near(compared.baselineWaitingSeconds, 3 * 3_600)
        near(compared.scenarioWaitingSeconds, 0); near(compared.savedHours, 3)
        precondition(compared.baselineWaitInterval == DateInterval(start: now.addingTimeInterval(15 * 3_600), end: reset))
        precondition(compared.normalResetDate == reset && compared.scenarioRelevant && compared.scenarioExhaustionDate == extra)
        for hour in [0.0, 3, 6, 8.5] {
            let sample = compared.sample(at: now.addingTimeInterval(hour * 3_600))!
            near(sample.baselineRemaining, 30 - hour * 2); near(sample.scenarioRemaining, 30 - hour * (30.0/9))
        }
        let planned=compared.scenarioSegments.first!
        precondition(planned.points.first?.date == now && planned.points.first?.remaining == window.remainingPercent)
        precondition(planned.points.last?.date == extra && planned.points.last?.remaining == 0,"The plan uses the current balance exactly at the selected reset")
        near(compared.sample(at:now.addingTimeInterval(4.5*3600))?.scenarioRemaining,15)
        precondition(window.remainingPercent == 30 && window.observedPercentPerHour == 2,"A spending plan never changes measured history or its pace")
        for segment in compared.historySegments+compared.baselineSegments+compared.scenarioSegments {
            precondition(segment.renderPoints.count == segment.points.count)
            for (a,b) in zip(segment.renderPoints,segment.points) {
                precondition(a.date == b.date && a.remaining == b.remaining && a.series == segment.id,
                             "Batch rendering preserves actual/history/scenario coordinates and reset discontinuities")
            }
        }
        let event = compared.sample(at: extra)!
        near(event.baselineRemaining, 12); near(event.scenarioRemaining, 100)
        let jump = compared.scenarioSegments.first { $0.kind == .resetJump }!
        precondition(jump.points.map(\.date) == [extra, extra] && jump.points.map(\.remaining) == [0, 100])
        precondition(compared.scenarioSegments.filter { $0.kind == .consuming && $0.id.hasPrefix("scenario.after") }.allSatisfy { segment in
            zip(segment.points, segment.points.dropFirst()).allSatisfy { pair in
                let hours = pair.1.date.timeIntervalSince(pair.0.date) / 3_600
                return hours > 0 && abs((pair.0.remaining - pair.1.remaining) / hours - 2) < 0.000_001
            }
        }, "The post-reset scenario must resume at the same frozen percentage-point pace")
        near(compared.sample(at: reset)?.scenarioRemaining, 82)
        near(compared.sample(at: reset)?.baselineRemaining, 0)
        precondition(compared.scenarioSegments.flatMap(\.points).allSatisfy { $0.date <= reset && (0...100).contains($0.remaining) })
        precondition(compared.baselineSegments.flatMap(\.points).allSatisfy { $0.date <= reset && (0...100).contains($0.remaining) })
        precondition(compared.sample(at: reset.addingTimeInterval(100))?.date == reset, "Inspection clamps to the supported horizon")
        precondition(compared.sample(at: Date(timeIntervalSince1970: .nan)) == nil)
        let disabled = UsageForecastComparison(window: window, now: now, extraResetDate: extra, assumesFullReset: true)
        let noAssumption = UsageForecastComparison(window: window, now: now, scenarioEnabled: true, extraResetDate: extra)
        for inactive in [disabled, noAssumption] {
            precondition(!inactive.scenarioRelevant && inactive.scenarioSegments.isEmpty && inactive.savedWaitingSeconds == nil)
        }
        for invalidDate in [now.addingTimeInterval(-1), now, now.addingTimeInterval(29 * 86_400),
                            Date(timeIntervalSince1970: .infinity)] {
            let invalid = UsageForecastComparison(window: window, now: now, scenarioEnabled: true,
                extraResetDate: invalidDate, assumesFullReset: true)
            precondition(!invalid.scenarioRelevant && invalid.extraResetDate == nil && invalid.scenarioSegments.isEmpty)
        }
        for irrelevantDate in [reset, reset.addingTimeInterval(3_600)] {
            let irrelevant = UsageForecastComparison(window: window, now: now, scenarioEnabled: true,
                extraResetDate: irrelevantDate, assumesFullReset: true)
            precondition(!irrelevant.scenarioRelevant && irrelevant.scenarioSegments.isEmpty && irrelevant.savedHours == nil)
            precondition(irrelevant.baselineSegments == baseline.baselineSegments && irrelevant.preExtraSafePercentPerHour == nil)
        }

        // A later target can slow the planned pace; it must still use the balance at that exact target.
        let late = UsageForecastComparison(window: window, now: now, scenarioEnabled: true,
            extraResetDate: now.addingTimeInterval(16 * 3_600), assumesFullReset: true)
        near(late.scenarioWaitingSeconds, 0); near(late.savedHours, 3)
        near(late.sample(at: now.addingTimeInterval(15.5 * 3_600))?.scenarioRemaining, 0.9375)
        near(late.sample(at: reset)?.scenarioRemaining, 96)

        // The plan avoids pre-reset waiting; the post-reset forecast can still deplete.
        let farReset = now.addingTimeInterval(80 * 3_600)
        let far = UsageForecastSnapshot(usage: response(reset: farReset), observations:
            readings(used: 70, start: 58, span: 6 * 3_600, now: now, reset: farReset), updated: now, now: now).windows[0]
        let twoWaits = UsageForecastComparison(window: far, now: now, scenarioEnabled: true,
            extraResetDate: now.addingTimeInterval(20 * 3_600), assumesFullReset: true)
        precondition(twoWaits.scenarioWaitingIntervals.count == 1)
        near(twoWaits.baselineWaitingSeconds, 65 * 3_600)
        near(twoWaits.scenarioWaitingSeconds, 10 * 3_600); near(twoWaits.savedHours, 55)
        near(twoWaits.sample(at: now.addingTimeInterval(75 * 3_600))?.scenarioRemaining, 0)

        // No expected exhaustion means no waiting to save, although the
        // explicitly simulated reset can still raise projected remaining.
        let enough = UsageForecastSnapshot(usage: response(used: 30, reset: reset), observations:
            readings(used: 30, start: 18, span: 6 * 3_600, now: now, reset: reset), updated: now, now: now).windows[0]
        let covered = UsageForecastComparison(window: enough, now: now, scenarioEnabled: true,
            extraResetDate: extra, assumesFullReset: true)
        near(covered.savedWaitingSeconds, 0)
        precondition(covered.baselineWaitingIntervals.isEmpty && covered.baselineExhaustionDate == nil)

        let exhausted = UsageForecastSnapshot(usage: response(used: 100, reset: reset), observations:
            readings(used: 100, start: 88, span: 6 * 3_600, now: now, reset: reset), updated: now, now: now).windows[0]
        precondition(exhausted.state == .exhausted); near(exhausted.observedPercentPerHour, 2)
        let resumed = UsageForecastComparison(window: exhausted, now: now, scenarioEnabled: true,
            extraResetDate: extra, assumesFullReset: true)
        near(resumed.baselineWaitingSeconds, 18 * 3_600); near(resumed.scenarioWaitingSeconds, 9 * 3_600)
        near(resumed.savedHours, 9); near(resumed.sample(at: reset)?.scenarioRemaining, 82)
        let depletedHistory = readings(used: 100, start: 88, span: 6 * 3_600, now: now, reset: reset)
        var plateau = UsageForecastObservation.merged(existing: depletedHistory, incoming: [], at: now)
        for seconds in [30.0, 60, 90, 300] {
            plateau = UsageForecastObservation.merged(existing: plateau, incoming:
                UsageForecastObservation.sanitized(usage: response(used: 100, reset: reset), accountKey: key,
                    at: now.addingTimeInterval(seconds)), at: now.addingTimeInterval(seconds))
        }
        precondition(plateau.first(where: { $0.usedPercent == 100 })?.observedAt == now,
                     "The earliest terminal reading survives same-bin coalescing")
        let freshTerminal = UsageForecastSnapshot(usage: response(used: 100, reset: reset), observations: plateau,
            updated: now.addingTimeInterval(300), now: now.addingTimeInterval(300)).windows[0]
        near(freshTerminal.observedPercentPerHour, 2)
        let oldTerminal = UsageForecastSnapshot(usage: response(used: 100, reset: reset), observations: plateau,
            updated: now.addingTimeInterval(301), now: now.addingTimeInterval(301)).windows[0]
        precondition(oldTerminal.state == .exhausted && oldTerminal.observedPercentPerHour == nil,
                     "Observed waiting cannot dilute or indefinitely refresh pre-depletion consumption")

        let coldZero = UsageForecastSnapshot(usage: response(used: 100, reset: reset), observations: [], updated: now, now: now).windows[0]
        let unknownResume = UsageForecastComparison(window: coldZero, now: now, scenarioEnabled: true,
            extraResetDate: extra, assumesFullReset: true)
        near(unknownResume.baselineWaitingSeconds, 18 * 3_600)
        precondition(unknownResume.scenarioSegments.isEmpty && unknownResume.scenarioWaitingSeconds == nil && unknownResume.savedHours == nil)
        precondition(unknownResume.sample(at: extra)?.scenarioRemaining == nil,
                     "Depleted factual waiting does not manufacture a post-reset consumption rate")

        for stateWindow in [
            UsageForecastSnapshot(usage: usage, observations: [], updated: now, now: now).windows[0],
            UsageForecastSnapshot(usage: usage, observations: readings(used: 70, start: 70, span: 6 * 3_600,
                now: now, reset: reset), updated: now, now: now).windows[0],
            UsageForecastSnapshot(usage: usage, observations: observations, updated: now.addingTimeInterval(-301), now: now).windows[0],
            UsageForecastSnapshot(usage: response(reset: nil), observations: observations, updated: now, now: now).windows[0],
            UsageForecastSnapshot(usage: response(reset: now.addingTimeInterval(-1)), observations: observations, updated: now, now: now).windows[0]
        ] {
            let unsupported = UsageForecastComparison(window: stateWindow, now: now, scenarioEnabled: true,
                extraResetDate: extra, assumesFullReset: true)
            precondition(unsupported.observedPercentPerHour == nil && unsupported.baselineSegments.isEmpty
                && unsupported.scenarioSegments.isEmpty && unsupported.savedHours == nil && unsupported.baselineExhaustionDate == nil)
        }
        let blocked = UsageForecastComparison(window: window, now: now, scenarioEnabled: true,
            extraResetDate: extra, assumesFullReset: true, quotaError: true)
        precondition(blocked.state == .unavailable && blocked.baselineSegments.isEmpty && blocked.scenarioSegments.isEmpty
            && blocked.normalSafePercentPerHour == nil && blocked.preExtraSafePercentPerHour == nil)
        let badNow = UsageForecastComparison(window: window, now: Date(timeIntervalSince1970: .nan))
        precondition(badNow.baselineSegments.isEmpty && badNow.domain.lowerBound.timeIntervalSince1970.isFinite)
    }

    static func closedSegmentRetention(now: Date) {
        let reset = now.addingTimeInterval(18 * 3_600)
        let firstCycle = readings(used: 70, start: 58, span: 6 * 3_600, now: now, reset: reset)
        var retained = UsageForecastObservation.merged(existing: firstCycle, incoming: [], at: now)
        let closedID = UsageForecastObservation.segments(retained, at: now)[0].id
        let newReset = reset.addingTimeInterval(7 * 86_400)
        for (seconds, used) in [(30.0, 10.0), (60, 10.2), (90, 10.3)] {
            let reading = UsageForecastObservation.sanitized(usage: response(used: used, reset: newReset), accountKey: key,
                at: now.addingTimeInterval(seconds))
            retained = UsageForecastObservation.merged(existing: retained, incoming: reading, at: now.addingTimeInterval(seconds))
        }
        let segments = UsageForecastObservation.segments(retained, at: now.addingTimeInterval(90))
        precondition(segments.count == 2 && segments[0].id == closedID && segments[0].observations.last?.usedPercent == 70)
        precondition(segments[1].observations.map(\.observedAt) == [now.addingTimeInterval(30), now.addingTimeInterval(90)],
                     "Same-bin updates preserve the new segment's first real endpoint and the old closed segment")
        let fresh = UsageForecastSnapshot(usage: response(used: 10.3, reset: newReset), observations: retained,
            updated: now.addingTimeInterval(90), now: now.addingTimeInterval(90)).windows[0]
        precondition(fresh.state == .learning && fresh.observedPercentPerHour == nil && fresh.observations.count == 2)

        // Old terminal data remains available for walk-forward evaluation,
        // even when the current cycle's supported rate is different.
        let end = now.addingTimeInterval(6 * 3_600 + 90)
        let secondCycle = readings(used: 34.3, start: 10.3, span: 6 * 3_600, now: end, reset: newReset)
        for row in secondCycle.dropFirst() {
            retained = UsageForecastObservation.merged(existing: retained, incoming: [row], at: row.observedAt)
        }
        precondition(UsageForecastObservation.segments(retained, at: end).count == 2)
        let result = UsageForecastSnapshot(usage: response(used: 34.3, reset: newReset), observations: retained,
            updated: end, now: end).windows[0]
        near(result.observedPercentPerHour, 4)
        precondition(result.observations.allSatisfy { $0.resetDate == newReset } && retained.contains { $0.resetDate == reset })

        // Segment IDs remain stable when the 512-row cap discards the first
        // endpoint, and the cap applies across closed and open segments.
        let long = readings(used: 90, start: 10, span: 240 * 3_600, now: now, reset: reset)
        let all = UsageForecastObservation.merged(existing: long, incoming: [], at: now)
        precondition(all.count == UsageForecastObservation.maximumSamplesPerWindow)
        let stableID = UsageForecastObservation.segments(all, at: now).last!.id
        let appended = UsageForecastObservation.merged(existing: all, incoming:
            UsageForecastObservation.sanitized(usage: response(used: 91, reset: reset), accountKey: key, at: now.addingTimeInterval(300)),
            at: now.addingTimeInterval(300))
        precondition(appended.count == UsageForecastObservation.maximumSamplesPerWindow && UsageForecastObservation.segments(appended, at: now.addingTimeInterval(300)).last!.id == stableID)
        let replayed = UsageForecastObservation.merged(existing: appended, incoming:
            UsageForecastObservation.sanitized(usage: response(used: 91, reset: reset), accountKey: key, at: now.addingTimeInterval(300)),
            at: now.addingTimeInterval(300))
        precondition(replayed == appended, "Replay remains idempotent when the caller has no segment metadata")
        let encoded = try! JSONEncoder().encode(retained)
        precondition(try! JSONDecoder().decode([UsageForecastObservation].self, from: encoded) == retained)
        let oldSchema = Data("[{\"windowID\":{\"bucketID\":\"codex\",\"role\":\"primary\"},\"observedAt\":0,\"usedPercent\":5,\"source\":\"synthetic\"}]".utf8)
        precondition((try! JSONDecoder().decode([UsageForecastObservation].self, from: oldSchema))[0].segmentID == nil)
    }

    static func binningAndRecentPace(now: Date) {
        let reset = now.addingTimeInterval(18 * 3_600)
        let raw = readings(used: 70, start: 58, span: 6 * 3_600, now: now, reset: reset, interval: 30)
        let merged = UsageForecastObservation.merged(existing: [], incoming: [], at: now)
        precondition(merged.isEmpty)
        var retained = [UsageForecastObservation]()
        for row in raw { retained = UsageForecastObservation.merged(existing: retained, incoming: [row], at: row.observedAt) }
        precondition(retained.count <= 75 && retained.first?.observedAt == raw.first?.observedAt
            && retained.last?.observedAt == raw.last?.observedAt && retained.last?.usedPercent == raw.last?.usedPercent)
        let result = UsageForecastSnapshot(usage: response(reset: reset), observations: retained, updated: now, now: now).windows[0]
        precondition(result.state == .ready && result.observations.count < 512)
        near(result.observedPercentPerHour, 2)
        let duplicated = UsageForecastObservation.merged(existing: retained, incoming: [retained.last!], at: now)
        precondition(duplicated == retained, "Exact replay is idempotent")
        let many = readings(used: 70, start: 20, span: 240 * 3_600, now: now, reset: reset)
        let bounded = UsageForecastObservation.merged(existing: many, incoming: [], at: now)
        precondition(bounded.count == UsageForecastObservation.maximumSamplesPerWindow && bounded.last?.observedAt == many.last?.observedAt
            && bounded.last?.usedPercent == many.last?.usedPercent, "512 bounds retained actual readings, not raw request frequency")
        let oldQuiet = readings(used: 58, start: 58, span: 36 * 3_600, now: now.addingTimeInterval(-6 * 3_600), reset: reset)
        let recent = readings(used: 70, start: 58, span: 6 * 3_600, now: now, reset: reset)
        let long = oldQuiet.dropLast() + recent
        let current = UsageForecastSnapshot(usage: response(reset: reset), observations: Array(long), updated: now, now: now).windows[0]
        near(current.observedPercentPerHour, 2)
        precondition(current.observations.first?.observedAt == now.addingTimeInterval(-6 * 3_600),
                     "Old quiet periods must not dilute the current six-hour pace")
    }

    static func sanitizer(now: Date) {
        let reset = now.addingTimeInterval(3_600)
        for invalidKey in [nil, "account-id", String(repeating: "A", count: 64), String(repeating: "a", count: 63)] as [String?] {
            precondition(UsageForecastObservation.sanitized(usage: response(reset: reset), accountKey: invalidKey, at: now).isEmpty)
        }
        for used in [-1, 101, Double.nan, Double.infinity] {
            precondition(UsageForecastObservation.sanitized(usage: response(used: used, reset: reset), accountKey: key, at: now).isEmpty)
        }
        for duration in [0, -1, 525_601] {
            precondition(UsageForecastObservation.sanitized(usage: response(duration: duration, reset: reset), accountKey: key, at: now).isEmpty)
        }
        precondition(UsageForecastObservation.sanitized(usage: response(reset: reset, bucket: "../bad"), accountKey: key, at: now).isEmpty)
        precondition(UsageForecastObservation.sanitized(usage: response(reset: reset), accountKey: key, at: now, source: "bad source").isEmpty)
        let accepted = UsageForecastObservation.sanitized(usage: response(duration: nil, reset: nil), accountKey: key, at: now)
        precondition(accepted.count == 1 && accepted[0].windowDurationMins == nil && accepted[0].resetDate == nil)
        let encoded = try! JSONEncoder().encode(accepted)
        let text = String(decoding: encoded, as: UTF8.self)
        precondition(!text.contains(key) && !text.contains("Synthetic display name") && !text.contains("availableCount"))
        let manyBuckets = (0..<9).reduce(into: [String:LimitBucket]()) { values, index in
            let id = "bucket\(index)"
            values[id] = response(reset: reset, bucket: id).rateLimits!
        }
        let bounded = UsageResponse(rateLimits: nil, rateLimitsByLimitId: manyBuckets, rateLimitResetCredits: nil)
        precondition(UsageForecastObservation.sanitized(usage: bounded, accountKey: key, at: now).count == 8)
    }

    struct FixtureWindow: Codable { let id: UsageForecastWindowID; let samples: [UsageForecastObservation] }
    struct FixtureAccount: Codable { let key: String; let lastSeen: Date; let windows: [FixtureWindow] }
    struct FixtureDocument: Codable { let schemaVersion: Int; let accounts: [FixtureAccount] }
    static func fixture(_ samples: [UsageForecastObservation], accounts: Int = 1, windows: Int = 1, schema: Int = 1, now: Date) throws -> Data {
        try JSONEncoder().encode(FixtureDocument(schemaVersion: schema, accounts: (0..<accounts).map { index in
            FixtureAccount(key: String(repeating: String(index, radix: 16), count: 64), lastSeen: now,
                windows: (0..<windows).map { window in
                    let id = UsageForecastWindowID(bucketID: "fixture\(window)", role: .primary)
                    return FixtureWindow(id: id, samples: samples.map { old in
                        UsageForecastObservation(windowID: id, observedAt: old.observedAt, usedPercent: old.usedPercent,
                            windowDurationMins: old.windowDurationMins, resetDate: old.resetDate, planType: old.planType, source: old.source)
                    })
                })
        }))
    }
    static func refused(_ body: () async throws -> Void) async {
        do { try await body(); preconditionFailure("Unsafe/corrupt operation was accepted") }
        catch {}
    }

    static func cache(now: Date) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/buddy-forecast-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("valid", isDirectory: true)
        let cache = UsageForecastCache(directory: directory)
        let reset = now.addingTimeInterval(7 * 86_400)
        let first = try await cache.record(usage: response(used: 20, reset: reset), accountKey: key, at: now)
        precondition(first.count == 1)
        let second = try await cache.record(usage: response(used: 20, reset: reset), accountKey: key, at: now.addingTimeInterval(60))
        precondition(second.count == 2 && second.last?.observedAt == now.addingTimeInterval(60), "Unchanged successful reads establish observed quiet time")
        let another = String(repeating: "b", count: 64)
        let other = try await cache.record(usage: response(used: 50, reset: reset), accountKey: another, at: now.addingTimeInterval(120))
        precondition(other.count == 1 && other[0].usedPercent == 50)
        let original = await cache.observations(accountKey: key, at: now.addingTimeInterval(120))
        precondition(original == second, "Accounts must never borrow observations")
        let size = try await cache.byteCount(); precondition(size > 0 && size <= UsageForecastCache.maximumBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.json").path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reader = UsageForecastCache(directory: directory)
        let reloaded = await reader.observations(accountKey: key, at: now.addingTimeInterval(120))
        precondition(reloaded == second)
        let epoch = await cache.generationToken()
        try await cache.clear()
        await refused { _ = try await cache.record(usage: response(reset: reset), accountKey: key, at: now, expectedGeneration: epoch) }
        let afterClear = await cache.observations(accountKey: key, at: now)
        precondition(afterClear.isEmpty && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
        let newEpoch = await cache.generationToken()
        _ = try await cache.record(usage: response(reset: reset), accountKey: key, at: now, expectedGeneration: newEpoch)

        let cyclesPath = root.appendingPathComponent("closed-cycles", isDirectory: true)
        let cycles = UsageForecastCache(directory: cyclesPath)
        _ = try await cycles.record(usage: response(used: 99, reset: reset), accountKey: key, at: now)
        _ = try await cycles.record(usage: response(used: 100, reset: reset), accountKey: key, at: now.addingTimeInterval(30))
        _ = try await cycles.record(usage: response(used: 100, reset: reset), accountKey: key, at: now.addingTimeInterval(60))
        let nextReset = reset.addingTimeInterval(7 * 86_400)
        let closedCycles = try await cycles.record(usage: response(used: 5, reset: nextReset), accountKey: key,
            at: now.addingTimeInterval(90))
        let cycleSegments = UsageForecastObservation.segments(closedCycles, at: now.addingTimeInterval(90))
        precondition(cycleSegments.count == 2 && cycleSegments[0].observations.contains { $0.usedPercent == 100 })
        let reloadedCycles = await UsageForecastCache(directory: cyclesPath).observations(accountKey: key, at: now.addingTimeInterval(90))
        precondition(reloadedCycles == closedCycles,
                     "Closed cycles and stable segment identity survive a real synthetic cache reload")

        let bound = UsageForecastCache(directory: root.appendingPathComponent("bounds", isDirectory: true))
        for index in 0..<5 {
            let account = String(repeating: String(index, radix: 16), count: 64)
            _ = try await bound.record(usage: response(reset: reset), accountKey: account, at: now.addingTimeInterval(Double(index) * 60))
        }
        let dropped = await bound.observations(accountKey: String(repeating: "0", count: 64), at: now.addingTimeInterval(300))
        precondition(dropped.isEmpty)
        let retained = await bound.observations(accountKey: String(repeating: "4", count: 64), at: now.addingTimeInterval(300))
        precondition(retained.count == 1)
        let windowBound = UsageForecastCache(directory: root.appendingPathComponent("window-bounds", isDirectory: true))
        for index in 0..<9 {
            _ = try await windowBound.record(usage: response(reset: reset, bucket: "bucket\(index)"), accountKey: key,
                at: now.addingTimeInterval(Double(index) * 60))
        }
        let retainedWindows = await windowBound.observations(accountKey: key, at: now.addingTimeInterval(600))
        precondition(retainedWindows.count == 8 && !retainedWindows.contains(where: { $0.windowID.bucketID == "bucket0" }))
        let sampleBoundPath = root.appendingPathComponent("sample-bound", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleBoundPath, withIntermediateDirectories: true)
        let historical = readings(used: 20, start: 10, span: 511 * 300, now: now, reset: reset)
        try fixture(historical, now: now).write(to: sampleBoundPath.appendingPathComponent("history.json"))
        let sampleBound = UsageForecastCache(directory: sampleBoundPath)
        let updated = try await sampleBound.record(usage: response(used: 20, reset: reset, bucket: "fixture0"),
            accountKey: String(repeating: "0", count: 64), at: now.addingTimeInterval(300))
        precondition(updated.count == 513 && updated.last?.observedAt == now.addingTimeInterval(300))
        precondition(Set(updated.compactMap(\.segmentID)).count == 1 && updated.allSatisfy { $0.segmentID != nil })
        precondition(UsageForecastObservation.segments(UsageForecastObservation.merged(existing: updated, incoming: [],
            at: now.addingTimeInterval(300)), at: now.addingTimeInterval(300)).count == 1,
                     "Upgrading and pruning legacy schema1 samples must not invent a new current cycle")

        let sample = UsageForecastObservation.sanitized(usage: response(reset: reset), accountKey: key, at: now)
        for (name, data) in [
            ("corrupt", Data("not-json".utf8)),
            ("schema", try fixture(sample, schema: 2, now: now)),
            ("accounts", try fixture(sample, accounts: 5, now: now)),
            ("windows", try fixture(sample, windows: 9, now: now)),
            ("samples", try fixture(Array(repeating: sample[0], count: UsageForecastObservation.maximumSamplesPerWindow+1), now: now))
        ] {
            let path = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try data.write(to: path.appendingPathComponent("history.json"))
            let invalid = UsageForecastCache(directory: path)
            let loaded = await invalid.observations(accountKey: String(repeating: "0", count: 64), at: now)
            precondition(loaded.isEmpty)
            await refused { _ = try await invalid.record(usage: response(reset: reset), accountKey: key, at: now) }
            try await invalid.clear()
            _ = try await invalid.record(usage: response(reset: reset), accountKey: key, at: now)
        }
        let oversized = root.appendingPathComponent("oversize", isDirectory: true)
        try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
        let big = oversized.appendingPathComponent("history.json")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: UInt64(UsageForecastCache.maximumBytes + 1)); try handle.close()
        let limited = UsageForecastCache(directory: oversized)
        await refused { _ = try await limited.record(usage: response(reset: reset), accountKey: key, at: now) }
        try await limited.clear(); precondition(!FileManager.default.fileExists(atPath: big.path))

        let victim = root.appendingPathComponent("synthetic-target.txt")
        let sentinel = Data("synthetic untouched target".utf8); try sentinel.write(to: victim)
        let leaf = root.appendingPathComponent("leaf-link", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: leaf.appendingPathComponent("history.json"), withDestinationURL: victim)
        let linked = UsageForecastCache(directory: leaf)
        await refused { _ = try await linked.record(usage: response(reset: reset), accountKey: key, at: now) }
        await refused { try await linked.clear() }
        let afterLeaf = try Data(contentsOf: victim); precondition(afterLeaf == sentinel)
        let targetDirectory = root.appendingPathComponent("synthetic-target-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("ancestor-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: targetDirectory)
        let ancestor = UsageForecastCache(directory: alias.appendingPathComponent("nested", isDirectory: true))
        await refused { _ = try await ancestor.record(usage: response(reset: reset), accountKey: key, at: now) }
        precondition(!FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("nested").path))
        let hard = root.appendingPathComponent("hard-link", isDirectory: true)
        try FileManager.default.createDirectory(at: hard, withIntermediateDirectories: true)
        precondition(Darwin.link(victim.path, hard.appendingPathComponent("history.json").path) == 0)
        let hardlinked = UsageForecastCache(directory: hard)
        await refused { _ = try await hardlinked.record(usage: response(reset: reset), accountKey: key, at: now) }
        let afterHard = try Data(contentsOf: victim); precondition(afterHard == sentinel)
        let expiredPath = root.appendingPathComponent("expired", isDirectory: true)
        try FileManager.default.createDirectory(at: expiredPath, withIntermediateDirectories: true)
        let oldDate = now.addingTimeInterval(-29 * 86_400)
        let oldSample = UsageForecastObservation.sanitized(usage: response(reset: reset), accountKey: key, at: oldDate)
        try fixture(oldSample, now: oldDate).write(to: expiredPath.appendingPathComponent("history.json"))
        let old = await UsageForecastCache(directory: expiredPath).observations(accountKey: String(repeating: "0", count: 64), at: now)
        precondition(old.isEmpty)
    }
}
