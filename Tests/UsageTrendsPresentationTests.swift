import AppKit
import SwiftUI
import Combine

@main struct UsageTrendsPresentationTests {
    @MainActor static func main() async throws {
        let model=AppModel(preferences:UsagePreviewPreferences(),client:UsageClient(credentialProvider:{ fatalError("Synthetic presentation cannot read credentials") }))
        model.useDemo()
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
        let now=calendar.date(from:DateComponents(year:2026,month:10,day:11,hour:12))!
        model.now=now;model.statistics=UsageStatistics(lifetimeTokens:4_860_000_000,peakDailyTokens:320_000_000,
            longestRunningTurnSec:22500,longestStreakDays:24,currentStreakDays:9,
            daily:[.init(day:"2026-10-10",tokens:162_000_000),.init(day:"2026-10-09",tokens:0),.init(day:"2026-09-01",tokens:12)])
        let state=UsageTrendsPresentation(model:model)
        precondition(state.sample && state.selectedID == "2026-10-10")
        precondition(state.calendarRange == .year && state.range == .days30 && state.calendarData == state.data.heatmap)
        precondition(state.chartPoints.count == 30 && state.chartPoints.last?.tokens == nil,"The curve keeps the entire range, including an unreported current day")
        precondition(state.periodTotal == 162_000_000 && state.periodTotalPartial && state.periodTotalText.hasPrefix("≥ "))
        precondition(state.chartYMaximum == 200_000_000 && state.chartYTicks == [0,50_000_000,100_000_000,150_000_000,200_000_000])
        precondition(state.points.last?.tokens == nil && state.maximum == 162_000_000)
        precondition(state.listPoints.count == 2 && state.listPoints.allSatisfy { $0.tokens != nil },"Initial records omit unavailable dates while retaining a reported zero")
        precondition(state.selectedDaily?.tokens == 162_000_000 && state.dailyChartPoints.count == 7 && state.sevenDayAverage == nil)
        let original=state.data
        var changes=0
        let observation=state.objectWillChange.sink { changes += 1 }
        for index in 1...20 { model.now=now.addingTimeInterval(Double(index)*30);model.menuShowsPercentage.toggle() }
        precondition(changes == 0 && state.data == original,"Quota ticks and same-day clock changes must not redraw trends")
        let annual=state.calendarData,annualRevision=state.calendarRevision
        state.calendarRange = .days30
        precondition(state.range == .days30 && state.calendarData.coverage.expectedDays == 30 && state.calendarRevision == annualRevision+1)
        let shortCalendar=state.calendarData,shortRevision=state.calendarRevision
        state.range = .days90
        precondition(state.chartPoints.count == 90 && state.calendarData == shortCalendar && state.calendarRevision == shortRevision,
                     "Curve controls must not rebuild or change the independent calendar")
        state.calendarRange = .days90
        precondition(state.calendarData.coverage.expectedDays == 90 && state.range == .days90)
        state.calendarRange = .year;state.range = .days30
        precondition(state.calendarData == annual && state.data == original)
        let fixedScale=state.chartYMaximum,selectionRevision=state.calendarRevision
        precondition(state.selectNearestChartDate(.distantPast) && state.selectedDaily?.day == "2026-10-09" && state.selectedDaily?.tokens == 0)
        precondition(state.selectNearestChartDate(.distantFuture) && state.selectedDaily?.day == "2026-10-10")
        precondition(state.selectNearestChartDate(calendar.startOfDay(for:now)) && state.selectedDaily?.day == "2026-10-10",
                     "A curve gesture near missing today selects a real reported point")
        precondition(!state.selectNearestChartDate(Date(timeIntervalSinceReferenceDate:.infinity)))
        let beforeSameSelection=changes
        _=state.selectNearestChartDate(.distantFuture)
        precondition(changes == beforeSameSelection && state.chartYMaximum == fixedScale && state.calendarRevision == selectionRevision,
                     "Repeated selection keeps data, calendar and axis fixed")
        state.grouping = .cumulative
        precondition(state.selected?.tokens == 162_000_000 && state.selected?.isPartial == true)
        precondition(UsageTrendFormat.value(state.selected!).hasPrefix("≥ "),"Partial totals must not imply complete history")
        precondition(state.chartPoints.count == 30 && state.calendarRevision == selectionRevision)
        let oldCell=state.data.heatmap.columns.flatMap(\.cells).first(where: { $0.day == "2026-09-01" })!
        state.selectDate(oldCell.date)
        precondition(state.range == .year && state.selectedID == "2026-09-01" && state.selected?.tokens == 12)
        let scrollRevision=state.scrollSelectionRevision
        state.grouping = .weekly
        precondition(state.selected!.startDate <= oldCell.date && oldCell.date <= state.selected!.endDate,"Grouping must retain the selected civil date")
        precondition(state.selectedSourceDate == oldCell.date,"Weekly/cumulative switching preserves the actual source date")
        precondition(state.selectedDaily?.day == "2026-09-01" && state.selectedDaily?.tokens == 12,"The inspector remains daily while the list is weekly")
        state.grouping = .daily
        precondition(state.selectedID == "2026-09-01" && state.scrollSelectionRevision > scrollRevision,"Group changes request linked list scrolling")
        precondition(state.selected?.tokens == 12 && state.maximum == 162_000_000)
        state.range = .days30
        precondition(state.selectedID == "2026-10-10","Changing range selects a valid reported day")
        let updated=now.addingTimeInterval(60)
        model.statisticsUpdated=updated
        precondition(state.updated == updated && state.data == original,"Freshness metadata must not rebuild records")
        state.range = .year
        let zero=state.data.heatmap.columns.flatMap(\.cells).first(where:{ $0.day == "2026-10-09" })!
        state.selectDate(zero.date)
        precondition(state.selectedDaily?.tokens == 0 && UsageTrendFormat.value(state.selectedDaily!) == "0")
        let unknown=state.data.heatmap.columns.flatMap(\.cells).first(where:{ $0.day == "2026-10-11" })!
        state.selectDate(unknown.date)
        precondition(state.selectedDaily != nil && state.selectedDaily?.tokens == nil && UsageTrendFormat.value(state.selectedDaily!) == "—")
        precondition(state.dailyChartPoints.last?.tokens == nil && state.sevenDayAverage == nil,"Unknown dates are inspectable without becoming zero or a fabricated average")
        func stats(_ days: [DailyTokenUsage]) -> UsageStatistics {
            UsageStatistics(lifetimeTokens:nil,peakDailyTokens:nil,longestRunningTurnSec:nil,longestStreakDays:nil,currentStreakDays:nil,daily:days)
        }
        let complete=(4...10).map { DailyTokenUsage(day:String(format:"2026-10-%02d",$0),tokens:Int64($0-3)*100) }
        model.statistics=stats(complete)
        state.selectDate(unknown.date.addingTimeInterval(-86_400))
        precondition(state.dailyChartPoints.count == 7 && state.sevenDayAverage == 400)
        state.grouping = .weekly
        state.select(state.listPoints.last!)
        precondition(state.selectedDaily?.day == "2026-10-10" && state.selectedDaily?.tokens == 700 && state.sevenDayAverage == 400,
                     "Selecting an aggregate uses the last real day for the daily inspector")
        model.statistics=stats(complete.filter { $0.day != "2026-10-07" })
        precondition(state.dailyChartPoints.count == 7 && state.dailyChartPoints.contains { $0.tokens == nil } && state.sevenDayAverage == nil,
                     "A missing civil date breaks the curve and suppresses the seven-day average")
        model.statistics=stats(complete.map { .init(day:$0.day,tokens:0) })
        precondition(state.sevenDayAverage == 0,"Seven explicit zeros are a valid measured average")
        model.statistics=stats(complete.map { .init(day:$0.day,tokens:Int64.max) })
        precondition(state.sevenDayAverage == nil,"An overflowing sum cannot produce a mean")
        precondition(state.periodTotal == nil && state.periodTotalOverflowed && state.periodTotalText == "—")
        precondition(state.chartYMaximum.isFinite && !UsageTrendFormat.chartTokens(state.chartYMaximum).isEmpty,
                     "A derived axis above Int64.max never casts a floating-point overflow")
        precondition(UsageTrendFormat.exactTokens(162_000_000) == "162,000,000")
        let beforeHover=changes,interaction=UsageTrendInteraction()
        var overlayChanges=0
        let overlayObservation=interaction.objectWillChange.sink { overlayChanges += 1 }
        interaction.hover("2026-10-10",active:true);interaction.hover("2026-10-10",active:true)
        precondition(overlayChanges == 1 && interaction.activeDay == "2026-10-10")
        interaction.focus("2026-10-09",active:true);interaction.hover("unrelated",active:false)
        precondition(interaction.activeDay == "2026-10-10")
        interaction.hover("2026-10-10",active:false)
        precondition(interaction.activeDay == "2026-10-09","Keyboard focus has the same immediate overlay path")
        interaction.focus("2026-10-09",active:false)
        precondition(interaction.activeDay == nil && changes == beforeHover,"Pointer/focus events must not publish trend-data changes")
        let bounds=CGRect(x:0,y:0,width:747,height:540),safe=bounds.insetBy(dx:8,dy:8)
        for anchor in [CGRect(x:0,y:0,width:8,height:8),CGRect(x:739,y:0,width:8,height:8),
                       CGRect(x:0,y:532,width:8,height:8),CGRect(x:739,y:532,width:8,height:8)] {
            let frame=UsageTrendTooltipPlacement.frame(anchor:anchor,size:CGSize(width:206,height:58),bounds:bounds)
            precondition(safe.contains(frame),"All four border cells keep the full tooltip in visible bounds")
        }
        let top=UsageTrendTooltipPlacement.frame(anchor:CGRect(x:300,y:4,width:10,height:10),size:CGSize(width:206,height:58),bounds:bounds)
        let bottom=UsageTrendTooltipPlacement.frame(anchor:CGRect(x:300,y:500,width:10,height:10),size:CGSize(width:206,height:58),bounds:bounds)
        precondition(top.minY >= 22 && bottom.maxY <= 492,"Top rows flip below; lower rows prefer above")
        let started=ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { _=state.points;_=state.maximum;_=UsageTrendFormat.date(now);_=UsageTrendFormat.exactTokens(162_000_000) }
        print(String(format:"1000 cached trend reads/formats: %.1fms",(ProcessInfo.processInfo.systemUptime-started)*1000))
        let navigation=UsageNavigationState();navigation.configure(.trends);navigation.page = .display;navigation.configure(.trends)
        precondition(navigation.page == .display && UsageSubpage.allCases.contains(.forecast),"Window reopen preserves the selected subpage and forecast remains independently reachable")
        model.statistics=stats(complete);state.grouping = .daily
        try await verifyRenderedAnchors(state:state,interaction:interaction)
        observation.cancel();overlayObservation.cancel()
        print("Trend presentation passed: isolated observation, real-only records, exact daily selection, complete-only averages, missing/zero/overflow, bounded immediate hover/focus and stable native anchors")
    }
    @MainActor private static func verifyRenderedAnchors(state: UsageTrendsPresentation,interaction: UsageTrendInteraction) async throws {
        NSApplication.shared.setActivationPolicy(.accessory);NSApp.finishLaunching()
        var frames=[String:CGRect]()
        let hosting=NSHostingView(rootView:UsageTrendsPage(state:state,interaction:interaction,framesChanged:{ frames=$0 }).environment(\.colorScheme,.dark))
        hosting.sizingOptions=[];hosting.autoresizingMask=[.width,.height]
        let window=NSWindow(contentRect:NSRect(x:100,y:100,width:811,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=hosting;window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<30 {
            hosting.layoutSubtreeIfNeeded()
            if frames["2026-10-10"] != nil { break }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        precondition(frames["2026-10-10"] != nil && frames.count >= 365,"Calendar cells must expose their actual native root anchors")
        let original=frames
        let valid=state.calendarData.columns.flatMap(\.cells).filter(\.insideRange)
        for day in [valid.first!.day,"2026-10-10","2026-10-11"] {
            interaction.hover(day,active:true)
            try await Task.sleep(nanoseconds:100_000_000);hosting.layoutSubtreeIfNeeded()
            precondition(frames == original,"An immediate tooltip must never shift the annual cells")
            interaction.hover(day,active:false);interaction.focus(day,active:true)
            try await Task.sleep(nanoseconds:100_000_000);hosting.layoutSubtreeIfNeeded()
            precondition(interaction.activeDay == day && frames == original,"Focus and hover share the same stationary overlay anchors")
            interaction.focus(day,active:false)
        }
    }
}
