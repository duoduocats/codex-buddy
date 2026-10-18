import AppKit
import SwiftUI
import Charts

@MainActor struct UsageForecastPage: View {
    @ObservedObject var state:UsageForecastPresentation
    @State private var hover=UsageForecastPlotHover()
    @State private var showingQuotaHistory=false
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:0) {
                    summary(width:max(1,geometry.size.width-58)).padding(.horizontal,-5)
                    comparisonSection(plotHeight:max(280,geometry.size.height-462-(geometry.size.width-58 < (AppLanguage.chinese ? 960 : 1000) ? 40 : 0))).padding(.top,30)
                    scenarioControls(width:max(1,geometry.size.width-58)).padding(.top,20)
                    guidance.padding(.top,22)
                }.padding(.horizontal,29).padding(.top,4).padding(.bottom,28)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }.overlayPreferenceValue(UsageForecastPlotAnchors.self) { anchors in
                UsageForecastHoverOverlay(hover:hover,comparison:state.comparison,anchor:anchors["plot"])
            }.onDisappear { hover.clear() }
                .onChange(of:state.selectedWindowID) { _ in hover.clear() }
                .onChange(of:state.extraResetEnabled) { _ in hover.clear() }
                .onChange(of:state.extraResetDate) { _ in hover.clear() }
        }.background(scheme == .dark ? Color(red:23/255,green:24/255,blue:25/255) : Color(nsColor:.windowBackgroundColor))
    }
    private func summary(width:CGFloat)->some View {
        let leading:CGFloat=width < 900 ? 24 : 60
        let groupedLeading:CGFloat=width < 900 ? 24 : 72
        return HStack(spacing:0) {
            VStack(alignment:.leading,spacing:10) {
                Text(state.waitingForUpdate || state.window?.state == .waiting ? L("上次剩余", "Last remaining") : L("当前剩余", "Current remaining")).font(.system(size:16,weight:.medium)).foregroundStyle(.secondary)
                Text(UsageForecastFormat.percent(state.window?.remainingPercent,digits:0))
                    .font(.system(size:38,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityIdentifier("usage-forecast-current-remaining")
            }.padding(.leading,leading).frame(width:width*0.25,alignment:.leading)
            Divider().frame(height:68)
            summaryGroup(L("常规", "Regular"),headline:state.baselineHeadline,detail:state.baselineDetail,color:.blue,leading:groupedLeading)
                .frame(width:width*0.35,alignment:.leading)
            Divider().frame(height:68)
            summaryGroup(L("额外重置情景", "Extra reset scenario"),headline:state.extraHeadline,detail:state.extraDetail,color:.orange,leading:groupedLeading)
                .frame(maxWidth:.infinity,alignment:.leading)
        }.frame(height:124)
            .background(Color.primary.opacity(0.012),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.11),lineWidth:0.7))
    }
    private func summaryGroup(_ title:String,headline:String,detail:String,color:Color,leading:CGFloat)->some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:10) {
                Circle().fill(color).frame(width:16,height:16).accessibilityHidden(true)
                Text(title).font(.system(size:18,weight:.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
            }
            Text(headline).font(.system(size:23,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .padding(.leading,26)
            Text(detail).font(.system(size:14)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                .padding(.leading,26)
        }.padding(.leading,leading).padding(.trailing,16).accessibilityElement(children:.combine)
    }
    private func comparisonSection(plotHeight:CGFloat)->some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(spacing:16) {
                Text(L("历史与预测", "History and forecast")).font(.system(size:24,weight:.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength:12)
                Button {showingQuotaHistory=true} label:{Label(L("额度历史", "Quota history"),systemImage:"clock.arrow.circlepath")}.buttonStyle(.plain).font(.system(size:13))
                    .popover(isPresented:$showingQuotaHistory) {UsageForecastHistoryPopover(title:L("已记录额度", "Recorded quota"),rows:state.quotaHistoryRows)}
                UsageForecastWindowMenu(state:state).frame(width:AppLanguage.chinese ? 118 : 164,height:34)
            }.frame(height:34)
            if let comparison=state.comparison {
                UsageForecastComparisonChart(state:state,comparison:comparison,hover:hover).frame(height:plotHeight).padding(.top,12)
                    .overlay(alignment:.topTrailing) {
                        if state.waitingForUpdate || state.comparison?.projectionBasis == .unavailable {
                            HStack(spacing:12) {
                                Text(state.headline).font(.system(size:13)).foregroundStyle(.secondary)
                                Button(L("刷新额度", "Refresh quota")) { state.refresh() }.buttonStyle(.bordered).disabled(state.refreshing)
                            }.padding(.top,40).padding(.trailing,12)
                        }
                    }
            } else {
                VStack(spacing:12) {
                    if state.refreshing { ProgressView() }
                    Text(state.headline).font(.system(size:16,weight:.medium)).foregroundStyle(.secondary)
                    Button(L("刷新额度", "Refresh quota")) { state.refresh() }.buttonStyle(.bordered).disabled(state.refreshing)
                }.frame(maxWidth:.infinity,minHeight:340)
            }
            HStack(spacing:36) {
                Spacer()
                legend(L("真实记录", "Recorded"),color:.secondary)
                legend(state.curveTitle,color:.blue)
                if state.extraResetEnabled && state.comparison?.scenarioSegments.isEmpty == false { legend(L("重置规划（模拟）", "Reset plan (scenario)"),color:.orange) }
                Spacer()
            }.frame(height:24).padding(.top,-10)
        }
    }
    private func legend(_ title:String,color:Color)->some View {
        HStack(spacing:9) {
            Path { path in path.move(to:CGPoint(x:0,y:1));path.addLine(to:CGPoint(x:36,y:1)) }
                .stroke(color,style:StrokeStyle(lineWidth:2,dash:[6,4])).frame(width:36,height:2)
                .overlay(Circle().fill(color).frame(width:7,height:7)).accessibilityHidden(true)
            Text(title).font(.system(size:14)).foregroundStyle(color == .blue ? Color.blue : Color.secondary)
        }
    }
    private func scenarioControls(width:CGFloat)->some View {
        Group {
            if width >= (AppLanguage.chinese ? 960 : 1000) {
                HStack(spacing:22) {
                    extraToggle
                    Divider().frame(height:36)
                    resetDateControl
                    Spacer(minLength:12)
                    tiboEstimateButton
                }.padding(.horizontal,22).frame(height:82)
            } else {
                VStack(alignment:.leading,spacing:14) {
                    HStack { extraToggle;Spacer(minLength:10);tiboEstimateButton }
                    resetDateControl
                }.padding(18)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.primary.opacity(0.018),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.11),lineWidth:0.7))
    }
    private var extraToggle:some View {
        HStack(spacing:24) {
            Text(L("额外重置（模拟）", "Extra reset (scenario)")).font(.system(size:16,weight:.semibold)).fixedSize(horizontal:true,vertical:false)
            Toggle(L("额外重置（模拟）", "Extra reset (scenario)"),isOn:$state.extraResetEnabled)
                .labelsHidden().toggleStyle(OverviewSwitchStyle(title:L("额外重置（模拟）", "Extra reset (scenario)")))
                .accessibilityIdentifier("usage-forecast-extra-enabled")
        }
    }
    private var resetDateControl:some View {
        HStack(spacing:14) {
            Image(systemName:"calendar").font(.system(size:22)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(L("重置时间", "Reset time")).font(.system(size:15)).foregroundStyle(.secondary).fixedSize(horizontal:true,vertical:false)
            UsageForecastDateControl(selection:$state.extraResetDate,minimum:state.now,
                maximum:state.now.addingTimeInterval(28*86400),enabled:state.extraResetEnabled)
                .frame(width:AppLanguage.chinese ? 214 : 252,height:34)
                .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.14),lineWidth:0.7).allowsHitTesting(false))
        }.frame(width:AppLanguage.chinese ? 324 : 374,alignment:.leading).fixedSize(horizontal:true,vertical:false)
    }
    private var tiboEstimateButton:some View {
        Button(L("使用 Tibo 估计", "Use Tibo estimate")) { state.applyTiboEstimate() }
            .font(.system(size:14,weight:.medium)).buttonStyle(.bordered).fixedSize(horizontal:true,vertical:false)
            .disabled(!state.tiboEstimateAvailable || !state.extraResetEnabled)
            .accessibilityIdentifier("usage-forecast-tibo-estimate")
    }
    private var guidance:some View {
        HStack(spacing:0) {
            pace(L("常规建议约", "Regular budget ≈"),value:state.baselineSafePercentPerHour,color:.blue)
            Divider().frame(height:38)
            pace(L("重置前规划约", "Before-reset plan ≈"),value:state.extraResetEnabled ? state.scenarioSafePercentPerHour : nil,color:.orange)
                .padding(.leading,40)
        }.padding(.horizontal,20).frame(height:48)
    }
    private func pace(_ title:String,value:Double?,color:Color)->some View {
        HStack(alignment:.firstTextBaseline,spacing:14) {
            Text(title).font(.system(size:16,weight:.medium)).lineLimit(2)
            HStack(alignment:.firstTextBaseline,spacing:5) {
                Text(UsageForecastFormat.percent(value)).font(.system(size:26,weight:.semibold)).monospacedDigit()
                if value != nil { Text(L("/ 小时", "/ hour")).font(.system(size:16,weight:.semibold)) }
            }.foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth:.infinity,alignment:.leading).accessibilityElement(children:.combine)
    }

}

@MainActor private struct UsageForecastHistoryPopover:View {
    let title:String
    let rows:[UsageForecastHistoryRow]
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(title).font(.system(size:19,weight:.semibold)).accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(L("暂无记录", "No records yet")).font(.system(size:14)).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:80)
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        ForEach(rows) { row in
                            VStack(alignment:.leading,spacing:5) {
                                HStack {
                                    Text(row.title).font(.system(size:14,weight:.semibold))
                                    Spacer()
                                    if let date=row.date { Text(UsageForecastFormat.date(date)).font(.system(size:12)).foregroundStyle(.secondary) }
                                }
                                Text(row.detail).font(.system(size:13)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                if let url=row.sourceURL { Link(L("查看来源", "View source"),destination:url).font(.system(size:12)) }
                            }
                            Divider()
                        }
                    }
                }.frame(maxHeight:350)
            }
        }.padding(22).frame(width:500)
    }
}

@MainActor private final class UsageForecastPlotHover:ObservableObject {
    @Published private(set) var date:Date?
    @Published private(set) var verticalFraction:CGFloat=0
    func set(date:Date,verticalFraction:CGFloat) {
        if self.date != date { self.date=date }
        if self.verticalFraction != verticalFraction { self.verticalFraction=verticalFraction }
    }
    func clear() { if date != nil { date=nil } }
}
private struct UsageForecastPlotAnchors:PreferenceKey {
    static var defaultValue:[String:Anchor<CGRect>]=[:]
    static func reduce(value:inout [String:Anchor<CGRect>],nextValue:()->[String:Anchor<CGRect>]) {
        value.merge(nextValue(),uniquingKeysWith:{ _,new in new })
    }
}

@MainActor private struct UsageForecastComparisonChart:View {
    @ObservedObject var state:UsageForecastPresentation
    let comparison:UsageForecastComparison
    let hover:UsageForecastPlotHover
    var body:some View {
        Chart {
            ForEach(Array(comparison.baselineWaitingIntervals.enumerated()),id:\.offset) { _,interval in
                RectangleMark(xStart:.value("Wait starts",interval.start),xEnd:.value("Wait ends",interval.end),
                    yStart:.value("Floor",0),yEnd:.value("Ceiling",100)).foregroundStyle(Color.blue.opacity(0.065))
                    .annotation(position:.overlay) {
                        VStack(spacing:4) {
                            Text(L("等待时段", "Waiting")).font(.system(size:12,weight:.medium))
                            Text(UsageForecastFormat.time(interval.start)+" – "+UsageForecastFormat.time(interval.end)).font(.system(size:11))
                        }.foregroundStyle(Color.blue.opacity(0.75))
                    }.accessibilityHidden(true)
            }
            paths(comparison.historySegments,color:.secondary,dashed:false)
            if let handoff=comparison.historyHandoff {
                ForEach(handoff.points) {point in
                    LineMark(x:.value("Time",point.date),y:.value("Last known",point.remaining),series:.value("Segment",handoff.id))
                        .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth:2,dash:[3,3])).interpolationMethod(.linear)
                        .accessibilityHidden(true)
                }
            }
            paths(comparison.baselineSegments,color:.blue,dashed:true)
            if state.extraResetEnabled { paths(visibleScenarioSegments,color:.orange,dashed:true) }
            if !state.waitingForUpdate,[UsageForecastState.ready,.learning,.quiet,.exhausted].contains(comparison.state),
               let remaining=state.window?.remainingPercent {
                RuleMark(x:.value("Now",state.now)).foregroundStyle(Color.blue.opacity(0.75)).lineStyle(StrokeStyle(lineWidth:1,dash:[3,3])).accessibilityHidden(true)
                PointMark(x:.value("Now",state.now),y:.value("Actual remaining",remaining))
                    .symbol { Circle().fill(Color.blue).overlay(Circle().stroke(Color.white,lineWidth:1.3)).frame(width:15,height:15) }
                    .annotation(position:.top,spacing:8) {
                        Text(UsageForecastFormat.percent(remaining,digits:0)).font(.system(size:15,weight:.semibold)).monospacedDigit()
                    }.accessibilityLabel(L("当前真实剩余", "Current actual remaining"))
            }
            if let first=comparison.historySegments.first?.points.first,state.now.timeIntervalSince(first.date) > max(60,comparison.domain.upperBound.timeIntervalSince(comparison.domain.lowerBound)*0.07) {
                PointMark(x:.value("Observed at",first.date),y:.value("Observed remaining",first.remaining))
                    .symbol { Circle().fill(Color.secondary).overlay(Circle().stroke(Color.white,lineWidth:1)).frame(width:8,height:8) }
                    .annotation(position:.top,alignment:.leading,spacing:8) {
                        Text(UsageForecastFormat.percent(first.remaining,digits:0)).font(.system(size:13,weight:.medium)).foregroundStyle(Color.secondary)
                    }
            }
            if let reset=comparison.regularResetDate,reset >= state.now,comparison.domain.contains(reset),
               let remaining=comparison.sample(at:reset)?.baselineRemaining {
                PointMark(x:.value("Regular reset",reset),y:.value("Projected remaining",remaining))
                    .symbol { Circle().fill(Color.blue).overlay(Circle().stroke(Color.white,lineWidth:1.2)).frame(width:15,height:15) }
                    .annotation(position:.top,alignment:.trailing,spacing:11) { marker(L("常规重置", "Regular reset"),color:.blue) }
                    .accessibilityHidden(true)
            }
        }.chartXScale(domain:comparison.domain).chartYScale(domain:0...100)
            .chartXAxis {
                AxisMarks(values:visibleAxisDates) { value in
                    AxisGridLine(stroke:StrokeStyle(lineWidth:0.7,dash:[3,3])).foregroundStyle(Color.primary.opacity(0.11))
                    AxisValueLabel(anchor:value.index == 0 ? .topLeading : value.index == visibleAxisDates.count-1 ? .topTrailing : .top,
                        collisionResolution:.disabled) {
                        if let date=value.as(Date.self) { Text(axisLabel(date)).font(.system(size:12)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position:.leading,values:[0,20,40,60,80,100]) { value in
                    AxisGridLine(stroke:StrokeStyle(lineWidth:0.7,dash:[3,3])).foregroundStyle(Color.primary.opacity(0.12))
                    AxisValueLabel {
                        if let percent=value.as(Int.self) { Text("\(percent)%").font(.system(size:12)).frame(width:39,alignment:.trailing) }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plot=geometry[proxy.plotAreaFrame]
                    ZStack {
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let point):
                                    guard plot.contains(point),let date:Date=proxy.value(atX:point.x-plot.minX) else { hover.clear();return }
                                    hover.set(date:date,verticalFraction:(point.y-plot.minY)/max(1,plot.height))
                                case .ended: hover.clear()
                                }
                            }
                        Color.clear.frame(width:plot.width,height:plot.height).position(x:plot.midX,y:plot.midY)
                            .anchorPreference(key:UsageForecastPlotAnchors.self,value:.bounds) { ["plot":$0] }
                            .allowsHitTesting(false)
                        if let nowX=proxy.position(forX:state.now) {
                            marker(L("现在 ", "Now ")+UsageForecastFormat.time(state.now),color:.blue)
                                .position(x:min(max(plot.minX+45,plot.minX+nowX),plot.maxX-45),y:plot.minY-16).allowsHitTesting(false)
                        }
                        if state.extraResetEnabled,let extra=comparison.extraResetDate,comparison.scenarioRelevant,
                           let x=proxy.position(forX:extra),let before=comparison.remainingAtExtraReset,
                           let y=proxy.position(forY:(before+100)/2) {
                            HStack(spacing:5) {
                                Image(systemName:"arrow.up").font(.system(size:13,weight:.medium))
                                Text(L("假设重置", "Assumed reset")).font(.system(size:12,weight:.medium))
                            }.foregroundStyle(Color.orange).fixedSize().position(x:min(plot.maxX-55,plot.minX+x+55),y:plot.minY+y)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                }
            }.accessibilityLabel(L("剩余额度的常规与额外重置对比", "Remaining quota with regular and extra-reset scenarios"))
            .accessibilityIdentifier("usage-forecast-comparison-plot").transaction { $0.animation=nil }
    }
    @ChartContentBuilder private func paths(_ segments:[UsageForecastCurveSegment],color:Color,dashed:Bool)->some ChartContent {
        ForEach(segments,id:\.id) { segment in
            renderedLine(segment,color:color,dashed:dashed)
            if !dashed,let point=segment.points.last {
                PointMark(x:.value("Time",point.date),y:.value("Observed remaining",point.remaining))
                    .foregroundStyle(color).symbolSize(12)
            }
            ForEach(dashed && segment.kind != .waiting ? segment.points : []) { point in
                if dashed && segment.kind != .waiting {
                    let keyPoint=segment.kind == .resetJump || (color == .orange && point.date == comparison.regularResetDate)
                    PointMark(x:.value("Time",point.date),y:.value("Remaining",point.remaining))
                        .symbol {
                            Circle().fill(color).overlay(Circle().stroke(keyPoint ? Color.white : Color.clear,lineWidth:1.2))
                                .frame(width:keyPoint ? 16 : 8,height:keyPoint ? 16 : 8)
                        }
                        .annotation(position:.top,spacing:7) {
                            if segment.kind != .resetJump && abs(point.date.timeIntervalSince(state.now)) > 60
                                && !(color == .blue && comparison.scenarioRelevant && point.date == comparison.extraResetDate)
                                && !(color == .orange && (segment.kind == .resetJump || segment.id == "scenario.before" || point.date == comparison.extraResetDate))
                                && (point.date == comparison.domain.upperBound || comparison.domain.upperBound.timeIntervalSince(point.date) >= comparison.domain.upperBound.timeIntervalSince(comparison.domain.lowerBound)*0.07) {
                                Text(UsageForecastFormat.percent(point.remaining,digits:0)).font(.system(size:12)).monospacedDigit()
                                    .foregroundStyle(segment.kind == .resetJump ? Color.orange : Color.secondary)
                            }
                        }
                }
            }
        }
    }
    private func renderedLine(_ segment:UsageForecastCurveSegment,color:Color,dashed:Bool)->AnyChartContent {
        if #available(macOS 15.0,*) {return AnyChartContent(UsageForecastBatchedLine(segment:segment,color:color,dashed:dashed))}
        return AnyChartContent(UsageForecastLegacyLine(segment:segment,color:color,dashed:dashed))
    }
    private var visibleScenarioSegments:[UsageForecastCurveSegment] {
        comparison.scenarioSegments
    }
    private var visibleAxisDates:[Date] {
        let dates=comparison.axisDates
        guard let first=dates.first,let last=dates.last,first < last else {return dates}
        let step=max(1,Int(ceil(Double(dates.count-1)/4)))
        let spacing=last.timeIntervalSince(first)*0.10
        var result=[first]
        for index in stride(from:step,to:dates.count-1,by:step) {
            let date=dates[index]
            if date.timeIntervalSince(result.last!) >= spacing && last.timeIntervalSince(date) >= spacing {result.append(date)}
        }
        result.append(last)
        return result
    }
    private func axisLabel(_ date:Date)->String {
        if comparison.domain.upperBound.timeIntervalSince(comparison.domain.lowerBound) >= 2*86400 {return UsageForecastFormat.day(date)}
        let index=comparison.axisDates.firstIndex(of:date) ?? 0
        if index == 0 || !UsageTrendsPresentation.calendar.isDate(date,inSameDayAs:comparison.axisDates[max(0,index-1)]) {
            return UsageForecastFormat.date(date)
        }
        return UsageForecastFormat.time(date)
    }
    private func marker(_ title:String,color:Color)->some View {
        Text(title).font(.system(size:11,weight:.semibold)).foregroundStyle(color)
            .padding(.horizontal,9).padding(.vertical,6).background(color.opacity(0.18),in:RoundedRectangle(cornerRadius:5))
            .overlay(RoundedRectangle(cornerRadius:5).stroke(color.opacity(0.5),lineWidth:0.6))
    }
}

@MainActor private struct UsageForecastHoverOverlay:View {
    @ObservedObject var hover:UsageForecastPlotHover
    let comparison:UsageForecastComparison?
    let anchor:Anchor<CGRect>?
    var body:some View {
        GeometryReader { geometry in
            if let date=hover.date,let comparison,let sample=comparison.sample(at:date),let anchor {
                let plot=geometry[anchor]
                let fraction=sample.date.timeIntervalSince(comparison.domain.lowerBound)/max(1,comparison.domain.upperBound.timeIntervalSince(comparison.domain.lowerBound))
                let origin=CGPoint(x:plot.minX+plot.width*fraction,y:plot.minY+plot.height*hover.verticalFraction)
                let count=[sample.observedRemaining,sample.carriedRemaining,sample.baselineRemaining,sample.scenarioRemaining].compactMap { $0 }.count
                let frame=UsageTrendTooltipPlacement.frame(anchor:CGRect(x:origin.x,y:origin.y,width:1,height:1),
                    size:CGSize(width:226,height:CGFloat(32+count*22)),bounds:CGRect(origin:.zero,size:geometry.size))
                VStack(alignment:.leading,spacing:5) {
                    Text(UsageForecastFormat.date(sample.date)).font(.system(size:12,weight:.medium))
                    if let value=sample.observedRemaining { row(L("实际观察", "Observed"),value:value,color:.primary) }
                    if let value=sample.carriedRemaining {row(L("最近观测", "Last observed"),value:value,color:.secondary)}
                    if let value=sample.baselineRemaining { row(L("常规", "Regular"),value:value,color:.blue) }
                    if let value=sample.scenarioRemaining { row(L("重置规划（模拟）", "Reset plan (scenario)"),value:value,color:.orange) }
                }.padding(12).frame(width:frame.width,height:frame.height,alignment:.leading)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.14),lineWidth:0.6))
                    .shadow(color:.black.opacity(0.16),radius:5,y:2).position(x:frame.midX,y:frame.midY)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func row(_ title:String,value:Double,color:Color)->some View {
        HStack { Text(title);Spacer(minLength:8);Text(UsageForecastFormat.percent(value)).monospacedDigit() }
            .font(.system(size:12)).foregroundStyle(color)
    }
}

@MainActor private struct UsageForecastWindowMenu:NSViewRepresentable {
    @ObservedObject var state:UsageForecastPresentation
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:UsageForecastPopupButton,context:Context)->CGSize? {
        CGSize(width:proposal.width ?? nsView.frame.width,height:proposal.height ?? 34)
    }
    func makeNSView(context:Context)->UsageForecastPopupButton {
        let button=UsageForecastPopupButton(frame:.zero,pullsDown:false)
        button.isBordered=false;button.font = .systemFont(ofSize:14);button.focusRingType = .exterior
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.setContentHuggingPriority(.defaultLow,for:.horizontal)
        button.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        button.target=context.coordinator;button.action=#selector(Coordinator.choose(_:))
        return button
    }
    func updateNSView(_ button:UsageForecastPopupButton,context:Context) {
        context.coordinator.parent=self
        let windows=state.snapshot.windows,ids=windows.map(\.id),titles=windows.map(state.windowLabel)
        if button.itemArray.map({ $0.representedObject as? String }) != ids.map(Optional.some) || button.itemTitles != titles {
            let menu=NSMenu();menu.autoenablesItems=false
            for (id,title) in zip(ids,titles) {
                let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");item.representedObject=id;menu.addItem(item)
            }
            button.menu=menu
        }
        if let window=state.window,let index=ids.firstIndex(of:window.id),button.indexOfSelectedItem != index { button.selectItem(at:index) }
        for item in button.itemArray { item.state=(item.representedObject as? String) == state.window?.id ? .on : .off }
        button.caption=state.window.map(state.windowLabel) ?? L("额度", "Quota")
        button.isEnabled = !windows.isEmpty;button.appearance=NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
        button.setAccessibilityLabel(L("预测额度", "Forecast window"));button.setAccessibilityValue(button.caption)
        button.setAccessibilityIdentifier("usage-forecast-window");button.needsDisplay=true
    }
    @MainActor final class Coordinator:NSObject {
        var parent:UsageForecastWindowMenu
        init(_ parent:UsageForecastWindowMenu) { self.parent=parent }
        @objc func choose(_ sender:UsageForecastPopupButton) {
            guard let id=sender.selectedItem?.representedObject as? String else { return }
            parent.state.selectWindow(id)
        }
    }
}

@MainActor private final class UsageForecastPopupButton:NSPopUpButton {
    var caption=""
    override var intrinsicContentSize:NSSize { NSSize(width:NSView.noIntrinsicMetric,height:34) }
    override var alignmentRectInsets:NSEdgeInsets { NSEdgeInsets(top:0,left:0,bottom:0,right:0) }
    override var acceptsFirstResponder:Bool { isEnabled }
    override var focusRingMaskBounds:NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill() }
    override func draw(_ dirtyRect:NSRect) {
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.35,dy:0.35),xRadius:8,yRadius:8)
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.075 : 0.045).setFill();path.fill()
        NSColor.labelColor.withAlphaComponent(0.11).setStroke();path.lineWidth=0.7;path.stroke()
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph]
        let height=(caption as NSString).size(withAttributes:attributes).height
        (caption as NSString).draw(in:NSRect(x:13,y:(bounds.height-height)/2,width:max(0,bounds.width-42),height:height),withAttributes:attributes)
        let arrow=NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:11,weight:.medium))?
            .withSymbolConfiguration(.init(paletteColors:[.secondaryLabelColor]))
        arrow?.draw(in:NSRect(x:bounds.maxX-21,y:bounds.midY-3.25,width:10,height:6.5),from:.zero,operation:.sourceOver,fraction:isEnabled ? 1 : 0.4,respectFlipped:true,hints:nil)
    }
}

@MainActor private struct UsageForecastDateControl:View {
    @Binding var selection:Date
    let minimum:Date
    let maximum:Date
    let enabled:Bool
    @State private var showingCalendar=false
    var body:some View {
        HStack(spacing:0) {
            UsageForecastNativeDatePicker(selection:$selection,minimum:minimum,maximum:maximum,enabled:enabled)
                .frame(width:AppLanguage.chinese ? 180 : 218,height:34)
            Button { showingCalendar.toggle() } label: {
                Image(systemName:"chevron.down").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                    .frame(width:24,height:34).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!enabled)
                .accessibilityLabel(L("选择模拟重置日期", "Choose simulated reset date"))
                .accessibilityIdentifier("usage-forecast-extra-calendar")
                .popover(isPresented:$showingCalendar,arrowEdge:.bottom) {
                    UsageForecastNativeCalendar(selection:$selection,minimum:minimum,maximum:maximum) { showingCalendar=false }
                        .fixedSize().padding(12)
                }
        }.padding(.horizontal,5)
            .onChange(of:enabled) { value in if !value { showingCalendar=false } }
            .onDisappear { showingCalendar=false }
    }
}

@MainActor private struct UsageForecastNativeCalendar:NSViewRepresentable {
    @Binding var selection:Date
    let minimum:Date
    let maximum:Date
    let onChoose:()->Void
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSDatePicker,context:Context)->CGSize? {
        nsView.intrinsicContentSize
    }
    func makeNSView(context:Context)->NSDatePicker {
        let picker=NSDatePicker(frame:.zero)
        picker.datePickerStyle = .clockAndCalendar;picker.datePickerMode = .single;picker.datePickerElements = .yearMonthDay
        picker.target=context.coordinator;picker.action=#selector(Coordinator.choose(_:))
        picker.setAccessibilityLabel(L("模拟重置日期", "Simulated reset date"))
        picker.setAccessibilityIdentifier("usage-forecast-extra-calendar-picker")
        return picker
    }
    func updateNSView(_ picker:NSDatePicker,context:Context) {
        context.coordinator.parent=self
        picker.appearance=NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
        let calendar=Calendar.autoupdatingCurrent
        picker.locale=AppLanguage.chinese ? Locale(identifier:"zh_CN") : .autoupdatingCurrent
        picker.minDate=calendar.startOfDay(for:minimum)
        let lastDay=calendar.startOfDay(for:maximum)
        picker.maxDate=calendar.date(byAdding:.day,value:1,to:lastDay)?.addingTimeInterval(-1) ?? maximum
        if picker.dateValue != selection { picker.dateValue=selection }
    }
    @MainActor final class Coordinator:NSObject {
        var parent:UsageForecastNativeCalendar
        init(_ parent:UsageForecastNativeCalendar) { self.parent=parent }
        @objc func choose(_ picker:NSDatePicker) {
            let calendar=Calendar.autoupdatingCurrent
            let time=calendar.dateComponents([.hour,.minute,.second],from:parent.selection)
            guard let selected=calendar.date(bySettingHour:time.hour ?? 0,minute:time.minute ?? 0,second:time.second ?? 0,
                of:picker.dateValue,matchingPolicy:.nextTime,repeatedTimePolicy:.first,direction:.forward) else { return }
            parent.selection=min(max(selected,parent.minimum),parent.maximum)
            parent.onChoose()
        }
    }
}

@MainActor private struct UsageForecastNativeDatePicker:NSViewRepresentable {
    @Binding var selection:Date
    let minimum:Date
    let maximum:Date
    let enabled:Bool
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:UsageForecastDatePicker,context:Context)->CGSize? {
        CGSize(width:proposal.width ?? nsView.frame.width,height:proposal.height ?? 34)
    }
    func makeNSView(context:Context)->UsageForecastDatePicker {
        let picker=UsageForecastDatePicker(frame:.zero)
        picker.datePickerStyle = .textField;picker.datePickerMode = .single;picker.datePickerElements=[.yearMonthDay,.hourMinute]
        picker.presentsCalendarOverlay=true;picker.font = .systemFont(ofSize:14);picker.isBezeled=false;picker.drawsBackground=false
        picker.setContentHuggingPriority(.defaultLow,for:.horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        picker.target=context.coordinator;picker.action=#selector(Coordinator.choose(_:))
        picker.setAccessibilityLabel(L("模拟重置时间", "Simulated reset time"));picker.setAccessibilityIdentifier("usage-forecast-extra-date")
        return picker
    }
    func updateNSView(_ picker:UsageForecastDatePicker,context:Context) {
        context.coordinator.parent=self
        picker.isEnabled=enabled;picker.appearance=NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
        let locale=AppLanguage.chinese ? Locale(identifier:"zh_CN") : Locale.autoupdatingCurrent
        if picker.locale != locale { picker.locale=locale }
        picker.minDate=minimum;picker.maxDate=maximum
        if picker.dateValue != selection { picker.dateValue=selection }
        picker.textColor = .labelColor;picker.backgroundColor=scheme == .dark ? NSColor(calibratedWhite:0.14,alpha:1) : .textBackgroundColor
    }
    @MainActor final class Coordinator:NSObject {
        var parent:UsageForecastNativeDatePicker
        init(_ parent:UsageForecastNativeDatePicker) { self.parent=parent }
        @objc func choose(_ picker:UsageForecastDatePicker) { parent.selection=picker.dateValue }
    }
}
@MainActor private final class UsageForecastDatePicker:NSDatePicker {
    override var alignmentRectInsets:NSEdgeInsets { NSEdgeInsets(top:0,left:0,bottom:0,right:0) }
    override var intrinsicContentSize:NSSize { NSSize(width:NSView.noIntrinsicMetric,height:34) }
}

@available(macOS 15.0,*)
@MainActor private struct UsageForecastBatchedLine:ChartContent {
    let segment:UsageForecastCurveSegment
    let color:Color
    let dashed:Bool
    @ChartContentBuilder var body:some ChartContent {
        LinePlot(segment.renderPoints,x:.value("Time",\.date),y:.value("Remaining",\.remaining),series:.value("Segment",\.series))
            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth:2,dash:dashed ? [7,5] : []))
            .interpolationMethod(.linear)
    }
}
@MainActor private struct UsageForecastLegacyLine:ChartContent {
    let segment:UsageForecastCurveSegment
    let color:Color
    let dashed:Bool
    @ChartContentBuilder var body:some ChartContent {
        ForEach(segment.points) {point in
            LineMark(x:.value("Time",point.date),y:.value("Remaining",point.remaining),series:.value("Segment",segment.id))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth:2,dash:dashed ? [7,5] : []))
                .interpolationMethod(.linear)
        }
    }
}
