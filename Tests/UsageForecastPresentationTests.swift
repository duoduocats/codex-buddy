import AppKit
import Combine

@main struct UsageForecastPresentationTests {
    @MainActor static func main() {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
        let now=calendar.date(from:DateComponents(year:2026,month:10,day:11,hour:12))!
        let reset=now.addingTimeInterval(18*3600)
        let model=AppModel(preferences:ForecastPresentationPreferences(),client:UsageClient(credentialProvider: {
            fatalError("Synthetic forecast presentation cannot read credentials")
        }))
        model.useDemo();model.now=now
        model.usage=usage(primary:70,reset:reset)
        model.forecastUpdated=now;model.forecastIdentity=String(repeating:"a",count:64)
        model.forecastObservations=observations(used:70,reset:reset,now:now)
        let state=UsageForecastPresentation(model:model)
        precondition(state.sample && state.window?.remainingPercent == 30)
        precondition(abs(state.currentPercentPerHour!-2) < 0.000_001)
        precondition(abs(state.safePercentPerHour!-30/18) < 0.000_001)
        precondition(abs(state.slowdownPercent!-100/6) < 0.000_001)
        precondition(state.availabilityDate == now.addingTimeInterval(15*3600) && state.exhaustsBeforeReset)
        precondition(UsageForecastFormat.number(state.safePercentPerHour) == UsageForecastFormat.number(1.7))
        precondition(UsageForecastFormat.percent(state.slowdownPercent,digits:0) == UsageForecastFormat.percent(17,digits:0))
        precondition(UsageForecastFormat.percent(.nan) == "—" && UsageForecastFormat.pace(.infinity) == "—")
        let baseline=state.snapshot.windows
        let originalUsage=model.usage
        let originalSelection=model.selection
        state.extraResetMode=true
        precondition(!state.simulated && state.snapshot.scenario == nil && state.snapshot.windows == baseline,
                     "Opening scenario controls must leave baseline active until the switch is enabled")
        state.extraResetDate=now.addingTimeInterval(9*3600);state.extraResetEnabled=true
        precondition(state.simulated && state.relevantScenario && state.effectiveResetDate == state.extraResetDate)
        precondition(state.availabilityDate == state.extraResetDate && abs(state.safePercentPerHour!-30/9) < 0.000_001)
        precondition(state.snapshot.windows == baseline && model.usage == originalUsage && model.selection == originalSelection,
                     "Extra reset simulation must preserve all actual quota windows and menu selection")
        precondition(abs(state.scenarioWindow!.remainingAtExtraReset!-12) < 0.000_001 && state.window?.remainingPercent == 30,
                     "Scenario projection must use remaining quota without adding an assumed reset grant")
        state.extraResetEnabled=false
        precondition(state.availabilityDate == now.addingTimeInterval(15*3600) && state.snapshot.scenario == nil)
        state.extraResetEnabled=true;state.extraResetMode=false
        precondition(state.simulated && state.snapshot.scenario != nil,"The single simulation switch must not depend on a second hidden mode")
        precondition(state.comparison?.baselineExhaustionDate == now.addingTimeInterval(15*3600))
        precondition(state.comparison?.savedWaitingSeconds == 3*3600)
        precondition(state.comparison?.scenarioSegments.first?.points.last?.remaining == 0 && state.comparison?.scenarioSegments.first?.points.last?.date == state.extraResetDate)
        precondition(state.extraHeadline == L("重置前用至 0%", "Use the balance before reset"))
        precondition(abs(state.comparison!.sample(at:reset)!.scenarioRemaining!-82) < 0.000_001)
        precondition(state.baselineHeadline == UsageForecastFormat.date(now.addingTimeInterval(15*3600)),
                     "The regular headline must remain tied to the blue baseline while the extra scenario is active")
        state.extraResetEnabled=false

        var redraws=0
        let subscription=state.objectWillChange.sink { redraws += 1 }
        model.now=now.addingTimeInterval(30);model.menuShowsPercentage.toggle();model.statisticsUpdated=now
        precondition(redraws == 0,"Unrelated model changes and same-minute clock ticks must not redraw forecast")
        model.error="synthetic-forecast-unavailable"
        precondition(state.waitingForUpdate && state.availabilityDate == nil && state.safePercentPerHour == nil && state.currentPercentPerHour == nil,
                     "Failed quota reads must suppress stale forecast certainty while retaining actual quota")
        precondition(state.window?.remainingPercent == 30 && state.effectiveResetDate == reset)
        state.extraResetEnabled=true
        precondition(state.extraHeadline == L("等待更新", "Awaiting update") && state.comparison?.scenarioSegments.isEmpty == true,
                     "An unavailable read cannot masquerade as an unchanged hypothetical reset")
        state.extraResetEnabled=false
        model.error=nil;model.now=now.addingTimeInterval(360)
        precondition(state.waitingForUpdate && state.availabilityDate == nil,"Forecast becomes unavailable after the source freshness window")
        model.now=now;model.forecastObservations=[]
        precondition(state.window?.state == .learning && state.availabilityDate == nil && state.currentPercentPerHour == nil)
        precondition(abs(state.safePercentPerHour!-30/18) < 0.000_001,"Cold start may show only the actual quota budget to reset")
        subscription.cancel()
        model.forecastObservations=observations(used:70,reset:reset,now:now,rate:0.1)
        precondition(state.window?.state == .quiet && state.currentPercentPerHour == nil && state.availabilityDate == nil,
                     "Small measured movement must not be represented as a zero rate or a confident ETA")
        precondition(state.headline == L("变化较小", "Small changes"))
        model.usage=usage(primary:100,reset:reset)
        precondition(state.window?.state == .exhausted && state.window?.remainingPercent == 0 && state.safePercentPerHour == 0)
        precondition(state.availabilityDate == nil && state.currentPercentPerHour == nil && state.headline == L("额度已用尽", "Quota exhausted"),
                     "A factual exhausted quota must not invent an observed rate or future availability")

        let shortReset=now.addingTimeInterval(6*3600)
        model.usage=usage(primary:70,reset:reset,secondary:98,secondaryReset:shortReset)
        model.forecastObservations=observations(used:70,reset:reset,now:now)
            + observations(used:98,reset:shortReset,now:now,role:.secondary,minutes:300,hours:1)
        let multiple=UsageForecastPresentation(model:model)
        precondition(multiple.window?.windowID.role == .secondary,"Default forecast must select the earliest ready limiting window")
        model.selection=1;multiple.selectWindow("codex.primary")
        precondition(multiple.window?.windowID.role == .primary && model.selection == 1,"Forecast picker must stay local to the page")
        model.forecastUpdated=now.addingTimeInterval(1)
        precondition(multiple.window?.windowID.role == .primary,"Explicit forecast selection must survive quota freshness updates")
        multiple.extraResetMode=true;multiple.extraResetEnabled=true
        model.forecastIdentity=String(repeating:"b",count:64)
        precondition(!multiple.extraResetEnabled,"Changing the account partition must disable the previous simulation")
        let simulatedFeed=(0..<3).map { index in
            ResetAnnouncement(id:"fixture-reset-\(index)",revision:1,type:"globalReset",status:.completed,
                publishedAt:now.addingTimeInterval(Double(index-2)*3600-1200),expiresAt:now.addingTimeInterval(86400),
                titleText:.init(zh:"模拟重置",en:"Synthetic reset"),bodyText:.init(zh:"模拟记录",en:"Synthetic record"),
                appliesToText:.init(zh:"模拟范围",en:"Synthetic scope"),
                sourceURL:URL(string:"https://x.com/thsottiaux/status/900000\(index)"),
                resetEffect:.immediateQuotaReset,globalScopeID:"synthetic-scope",campaignID:"synthetic-campaign")
        }
        model.reminders.useDemo(now:now,messages:simulatedFeed);model.now=now.addingTimeInterval(60)
        precondition(multiple.tiboEstimateAvailable && multiple.tiboHistoryRows.count == 3)
        let actualBeforeEstimate=model.usage;multiple.applyTiboEstimate()
        precondition(multiple.extraResetEnabled && multiple.extraResetDate == now.addingTimeInterval(2400))
        precondition(model.usage == actualBeforeEstimate,"Applying an announcement-clock estimate must only change the local hypothetical date")
        model.reminders.setMessagesEnabled(false);model.now=now.addingTimeInterval(120)
        precondition(multiple.tiboHistoryRows.isEmpty && !multiple.tiboEstimateAvailable,
                     "Turning reception off must hide activity inputs and disable historical estimates without fetching")
        model.client.stop()
        print("Forecast presentation passed: fixed baseline with one-switch counterfactual, target-date budget comparison and waiting savings, independent selection, cold/stale/error states, isolated redraws and synthetic privacy")
    }
    private static func usage(primary:Double,reset:Date,secondary:Double? = nil,secondaryReset:Date? = nil) -> UsageResponse {
        let bucket=LimitBucket(limitId:"codex",limitName:nil,
            primary:LimitWindow(usedPercent:primary,windowDurationMins:10080,resetsAt:reset.timeIntervalSince1970),
            secondary:secondary.map { LimitWindow(usedPercent:$0,windowDurationMins:300,resetsAt:secondaryReset?.timeIntervalSince1970) },planType:"test")
        return UsageResponse(rateLimits:bucket,rateLimitsByLimitId:nil,rateLimitResetCredits:nil)
    }
    private static func observations(used:Double,reset:Date,now:Date,role:UsageForecastWindowRole = .primary,
                                     minutes:Int = 10080,hours:Int = 6,rate:Double = 2) -> [UsageForecastObservation] {
        (0...hours*12).map { index in
            let age=Double(hours*12-index)*300
            return UsageForecastObservation(windowID:.init(bucketID:"codex",role:role),observedAt:now.addingTimeInterval(-age),
                usedPercent:used-age*rate/3600,windowDurationMins:minutes,resetDate:reset,planType:"test",source:"synthetic-forecast")
        }
    }
}

private final class ForecastPresentationPreferences: UserDefaults {
    private var values=[String:Any]()
    override func object(forKey key:String) -> Any? { values[key] }
    override func bool(forKey key:String) -> Bool { values[key] as? Bool ?? false }
    override func integer(forKey key:String) -> Int { values[key] as? Int ?? 0 }
    override func string(forKey key:String) -> String? { values[key] as? String }
    override func data(forKey key:String) -> Data? { values[key] as? Data }
    override func dictionary(forKey key:String) -> [String:Any]? { values[key] as? [String:Any] }
    override func set(_ value:Any?,forKey key:String) { values[key]=value }
    override func removeObject(forKey key:String) { values.removeValue(forKey:key) }
}
