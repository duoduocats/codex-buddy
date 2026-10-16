import AppKit
import SwiftUI
import Charts

// Only the floating overlay observes pointer/focus changes. Moving over cells
// cannot invalidate statistics, the date list or the rest of the page.
@MainActor final class UsageTrendInteraction: ObservableObject {
    @Published private(set) var hoveredDay: String?
    @Published private(set) var focusedDay: String?
    var activeDay: String? { hoveredDay ?? focusedDay }
    func hover(_ day: String,active: Bool) {
        if active { if hoveredDay != day { hoveredDay=day } }
        else if hoveredDay == day { hoveredDay=nil }
    }
    func focus(_ day: String,active: Bool) {
        if active { if focusedDay != day { focusedDay=day } }
        else if focusedDay == day { focusedDay=nil }
    }
    func clear() {
        if hoveredDay != nil { hoveredDay=nil }
        if focusedDay != nil { focusedDay=nil }
    }
}

enum UsageTrendTooltipPlacement {
    static func frame(anchor: CGRect,size: CGSize,bounds: CGRect,margin: CGFloat = 8,gap: CGFloat = 8) -> CGRect {
        let inset=bounds.insetBy(dx:margin,dy:margin)
        let width=min(size.width,max(0,inset.width)),height=min(size.height,max(0,inset.height))
        let x=min(max(inset.minX,anchor.midX-width/2),max(inset.minX,inset.maxX-width))
        let above=anchor.minY-gap-height
        let proposedY=above >= inset.minY ? above : anchor.maxY+gap
        let y=min(max(inset.minY,proposedY),max(inset.minY,inset.maxY-height))
        return CGRect(x:x,y:y,width:width,height:height)
    }
}

private struct UsageTrendCellAnchors: PreferenceKey {
    static var defaultValue: [String:Anchor<CGRect>] = [:]
    static func reduce(value: inout [String:Anchor<CGRect>],nextValue: () -> [String:Anchor<CGRect>]) {
        value.merge(nextValue(),uniquingKeysWith:{ _,new in new })
    }
}

@MainActor struct UsageTrendsPage: View {
    @ObservedObject var state: UsageTrendsPresentation
    @State private var interaction = UsageTrendInteraction()
    private let framesChanged: (([String:CGRect]) -> Void)?
    @Environment(\.colorScheme) private var scheme
    init(state: UsageTrendsPresentation,interaction: UsageTrendInteraction? = nil,framesChanged: (([String:CGRect]) -> Void)? = nil) {
        self.state=state;self.framesChanged=framesChanged
        _interaction=State(initialValue:interaction ?? UsageTrendInteraction())
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:0) {
                    summary.padding(.horizontal,-5)
                    if let error=state.error {
                        HStack(spacing:10) {
                            Image(systemName:"exclamationmark.circle").accessibilityHidden(true)
                            Text(error).fixedSize(horizontal:false,vertical:true)
                            Spacer(minLength:12)
                            Button(L("重试", "Retry")) { state.refresh() }.buttonStyle(.link).disabled(state.refreshing)
                        }.font(.system(size:12)).foregroundStyle(.secondary).padding(.top,16)
                    }
                    if state.statistics?.daily?.isEmpty == false {
                        UsageTrendCalendar(state:state,interaction:interaction,width:max(1,geometry.size.width-58))
                            .padding(.top,46)
                        Divider().padding(.top,40)
                        UsageTrendFullChart(state:state).padding(.top,38)
                        UsageTrendRecordedList(state:state).padding(.top,24)
                    } else {
                        emptyState.frame(maxWidth:.infinity,minHeight:320).padding(.top,46)
                    }
                }.padding(.horizontal,29).padding(.top,16).padding(.bottom,30)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }.overlayPreferenceValue(UsageTrendCellAnchors.self) { anchors in
                UsageTrendTooltipOverlay(interaction:interaction,map:state.calendarData,anchors:anchors,framesChanged:framesChanged)
            }.onDisappear { interaction.clear() }
                .onChange(of:state.calendarRange) { _ in
                    if let day=interaction.activeDay,!state.calendarData.columns.flatMap(\.cells).contains(where:{ $0.day == day && $0.insideRange }) { interaction.clear() }
                }
        }.background(scheme == .dark ? Color(red:23/255,green:24/255,blue:25/255) : Color(nsColor:.windowBackgroundColor))
    }
    private var summary: some View {
        HStack(spacing:0) {
            metric(L("累计 Token 数", "Lifetime tokens"),value:UsageTrendFormat.tokens(state.statistics?.lifetimeTokens))
            Divider().frame(height:60)
            metric(L("Token 使用峰值", "Peak daily tokens"),value:UsageTrendFormat.tokens(state.statistics?.peakDailyTokens))
            Divider().frame(height:60)
            metric(L("最长任务用时", "Longest task"),value:UsageTrendFormat.duration(state.statistics?.longestRunningTurnSec))
            Divider().frame(height:60)
            metric(L("最长连续天数", "Longest streak"),value:StatisticsFormat.days(state.statistics?.longestStreakDays))
            Divider().frame(height:60)
            metric(L("当前连续天数", "Current streak"),value:StatisticsFormat.days(state.statistics?.currentStreakDays))
        }.frame(height:100)
            .background(Color.primary.opacity(scheme == .dark ? 0.008 : 0.015),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.11),lineWidth:0.7))
    }
    private func metric(_ label: String,value: String) -> some View {
        VStack(spacing:8) {
            Text(value).font(.system(size:30,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size:15)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }.offset(y:-3).frame(maxWidth:.infinity).padding(.horizontal,8).accessibilityElement(children:.combine)
    }
    private var emptyState: some View {
        VStack(spacing:14) {
            if state.refreshing { ProgressView() }
            else { Image(systemName:"chart.bar.xaxis").font(.system(size:28,weight:.light)).foregroundStyle(.secondary).accessibilityHidden(true) }
            Text(state.refreshing ? L("正在读取用量…", "Loading usage…") : emptyTitle).font(.system(size:15,weight:.medium))
            Button(L("刷新", "Refresh")) { state.refresh() }.buttonStyle(.bordered).disabled(state.refreshing)
        }.padding(24)
    }
    private var emptyTitle: String {
        state.statistics?.daily == nil ? L("暂时无法读取用量", "Usage is unavailable") : L("还没有用量记录", "No usage recorded yet")
    }
}

@MainActor private struct UsageTrendRangeMenu: View {
    @Binding var selection: UsageTrendRange
    let calendar: Bool
    let width: CGFloat
    let label: String
    let identifier: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        UsageTrendNativeRangePopup(selection:$selection,calendar:calendar,label:label,identifier:identifier,
            dark:scheme == .dark,enabled:enabled).frame(width:width,height:32)
    }
}

@MainActor private struct UsageTrendNativeRangePopup: NSViewRepresentable {
    @Binding var selection: UsageTrendRange
    let calendar: Bool
    let label: String
    let identifier: String
    let dark: Bool
    let enabled: Bool
    private var choices: [UsageTrendRange] { calendar ? [.year,.days90,.days30] : [.days30,.days90,.year] }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:UsageTrendNativePopupButton,context:Context) -> CGSize? {
        CGSize(width:proposal.width ?? nsView.frame.width,height:proposal.height ?? 32)
    }
    func makeNSView(context:Context) -> UsageTrendNativePopupButton {
        let button=UsageTrendNativePopupButton(frame:.zero,pullsDown:false)
        button.isBordered=false;button.font = .systemFont(ofSize:14);button.focusRingType = .exterior
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.cell?.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow,for:.horizontal)
        button.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        button.target=context.coordinator;button.action=#selector(Coordinator.choose(_:))
        return button
    }
    func updateNSView(_ button:UsageTrendNativePopupButton,context:Context) {
        context.coordinator.parent=self
        let values=choices.map { $0.rawValue },titles=choices.map(title)
        if button.itemArray.map({ $0.representedObject as? String }) != values.map(Optional.some)
            || button.itemTitles != titles {
            let menu=NSMenu();menu.autoenablesItems=false
            for value in choices {
                let item=NSMenuItem(title:title(value),action:nil,keyEquivalent:"")
                item.representedObject=value.rawValue;menu.addItem(item)
            }
            button.menu=menu
        }
        let index=choices.firstIndex(of:selection) ?? 0
        if button.indexOfSelectedItem != index { button.selectItem(at:index) }
        for item in button.itemArray { item.state=(item.representedObject as? String) == selection.rawValue ? .on : .off }
        button.displayCaption=displayTitle(selection);button.isEnabled=enabled
        button.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
        button.setAccessibilityLabel(label);button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityValue(title(selection));button.needsDisplay=true
    }
    private func displayTitle(_ value:UsageTrendRange) -> String {
        switch value {
        case .year: return title(value)
        case .days90: return L("近90天", "90 days")
        case .days30: return L("近30天", "30 days")
        }
    }
    private func title(_ value:UsageTrendRange) -> String {
        switch value {
        case .year: return calendar ? L("年度", "Year") : L("一年", "One year")
        case .days90: return calendar ? L("近90天", "90 days") : L("近90天", "Last 90 days")
        case .days30: return calendar ? L("近30天", "30 days") : L("近30天", "Last 30 days")
        }
    }
    @MainActor final class Coordinator:NSObject {
        var parent:UsageTrendNativeRangePopup
        init(_ parent:UsageTrendNativeRangePopup) { self.parent=parent }
        @objc func choose(_ sender:UsageTrendNativePopupButton) {
            guard let raw=sender.selectedItem?.representedObject as? String,let value=UsageTrendRange(rawValue:raw) else { return }
            parent.selection=value;sender.displayCaption=parent.displayTitle(value)
            sender.setAccessibilityValue(parent.title(value))
            for item in sender.itemArray { item.state=item === sender.selectedItem ? .on : .off }
            sender.needsDisplay=true
        }
    }
}

// The native control itself occupies the complete styled rectangle. Its mouse,
// keyboard and accessibility popup tracking remain AppKit's standard behavior.
@MainActor private final class UsageTrendNativePopupButton:NSPopUpButton {
    var displayCaption=""
    override var intrinsicContentSize:NSSize { NSSize(width:NSView.noIntrinsicMetric,height:32) }
    override var alignmentRectInsets:NSEdgeInsets { NSEdgeInsets(top:0,left:0,bottom:0,right:0) }
    override var acceptsFirstResponder:Bool { isEnabled }
    override var focusRingMaskBounds:NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill() }
    override func draw(_ dirtyRect:NSRect) {
        let rect=bounds.insetBy(dx:0.35,dy:0.35)
        let path=NSBezierPath(roundedRect:rect,xRadius:8,yRadius:8)
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.075 : 0.045).setFill();path.fill()
        NSColor.labelColor.withAlphaComponent(0.11).setStroke();path.lineWidth=0.7;path.stroke()
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:14),
            .foregroundColor:NSColor.labelColor.withAlphaComponent(isEnabled ? 1 : 0.4),.paragraphStyle:paragraph]
        let height=(displayCaption as NSString).size(withAttributes:attributes).height
        (displayCaption as NSString).draw(in:NSRect(x:13,y:(bounds.height-height)/2,
            width:max(0,bounds.width-42),height:height),withAttributes:attributes)
        let config=NSImage.SymbolConfiguration(pointSize:11,weight:.medium)
        let arrow=NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil)?
            .withSymbolConfiguration(config)?.withSymbolConfiguration(.init(paletteColors:[.secondaryLabelColor]))
        arrow?.draw(in:NSRect(x:bounds.maxX-21,y:bounds.midY-3.25,width:10,height:6.5),
            from:.zero,operation:.sourceOver,fraction:isEnabled ? 1 : 0.4,respectFlipped:true,hints:nil)
    }
}

@MainActor private struct UsageTrendCalendar: View {
    @ObservedObject var state: UsageTrendsPresentation
    let interaction: UsageTrendInteraction
    let width: CGFloat
    private var map: UsageTrendHeatmap { state.calendarData }
    private let gap: CGFloat=4.5
    private var cellSize: CGFloat {
        let count=CGFloat(max(1,map.columns.count))
        let stretched=max(5,(width-CGFloat(max(0,map.columns.count-1))*gap)/count)
        return state.calendarRange == .year ? stretched : min(24,stretched)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:28) {
            HStack(spacing:22) {
                Text(L("Token 活动", "Token activity")).font(.system(size:22,weight:.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength:12)
                UsageTrendRangeMenu(selection:$state.calendarRange,calendar:true,width:99,
                    label:L("日历范围", "Calendar range"),identifier:"usage-calendar-range")
            }.frame(height:34)
            VStack(alignment:.leading,spacing:18) {
                HStack(spacing:gap) {
                    ForEach(map.columns) { column in
                        VStack(spacing:gap) {
                            ForEach(column.cells) { cell in
                                UsageTrendCalendarCell(cell:cell,size:cellSize,selected:state.selectedDay == cell.day,
                                    interaction:interaction,action:{ state.selectDate(cell.date) })
                            }
                        }
                    }
                }
                ZStack(alignment:.topLeading) {
                    ForEach(ticks) { tick in
                        Text(UsageTrendFormat.month(tick.date,year:false)).font(.system(size:12)).foregroundStyle(.secondary)
                            .offset(x:monthX(tick))
                    }
                }.frame(height:14)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private func groupingButton(_ grouping: UsageTrendGrouping,_ title: String,width: CGFloat) -> some View {
        Button { state.grouping=grouping } label: {
            Text(title).font(.system(size:16,weight:state.grouping == grouping ? .semibold : .regular))
                .foregroundStyle(state.grouping == grouping ? Color.primary : Color.secondary)
                .frame(width:width,height:32).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(state.grouping == grouping ? .isSelected : [])
            .accessibilityIdentifier("usage-trends-group-"+grouping.rawValue)
    }
    private func monthWidth(_ tick: UsageTrendMonthTick) -> CGFloat {
        (UsageTrendFormat.month(tick.date,year:false) as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)]).width+2
    }
    private func monthX(_ tick: UsageTrendMonthTick) -> CGFloat {
        let gridWidth=CGFloat(map.columns.count)*cellSize+CGFloat(max(0,map.columns.count-1))*gap
        return min(max(0,CGFloat(tick.column)*(cellSize+gap)),max(0,gridWidth-monthWidth(tick)))
    }
    private var ticks: [UsageTrendMonthTick] {
        var previousRight: CGFloat = -100
        let first=map.monthTicks.first
        let hidePartialFirst=UsageTrendsPresentation.calendar.component(.day,from:map.startDate) > 1 && map.monthTicks.count > 12
        return map.monthTicks.filter { tick in
            if hidePartialFirst && tick == first { return false }
            let x=monthX(tick)
            guard x-previousRight >= 6 else { return false }
            previousRight=x+monthWidth(tick);return true
        }
    }
}

@MainActor private struct UsageTrendFullChart: View {
    @ObservedObject var state: UsageTrendsPresentation
    @State private var hoveredPointID:String?
    private var activePoint:UsageTrendPoint? {hoveredPointID.flatMap {id in state.chartPoints.first {$0.id == id}} ?? state.selected}
    private var pointLabel:String {
        guard let point=activePoint else {return ""}
        return state.grouping == .weekly ? UsageTrendFormat.date(point.periodStartDate)+" – "+UsageTrendFormat.date(point.periodEndDate) : UsageTrendFormat.date(point.date)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:32) {
            HStack(alignment:.firstTextBaseline,spacing:24) {
                Text(L("用量走势", "Usage trend")).font(.system(size:22,weight:.semibold)).accessibilityAddTraits(.isHeader)
                HStack(spacing:3) {
                    ForEach(UsageTrendGrouping.allCases,id:\.self) {mode in
                        Button {state.grouping=mode} label:{
                            Text(mode == .daily ? L("日", "Day") : mode == .weekly ? L("周", "Week") : L("累计", "Total"))
                                .font(.system(size:12,weight:.medium)).frame(width:AppLanguage.chinese ? 43 : 50,height:28)
                                .background(state.grouping == mode ? Color.accentColor.opacity(0.17) : Color.clear,in:RoundedRectangle(cornerRadius:6))
                                .foregroundStyle(state.grouping == mode ? Color.accentColor : Color.secondary).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(state.grouping == mode ? .isSelected : [])
                            .accessibilityIdentifier("usage-trends-group-"+mode.rawValue)
                    }
                }.padding(3).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:8))
                    .accessibilityElement(children:.contain).accessibilityLabel(L("曲线统计方式", "Chart aggregation"))
                Spacer(minLength:8)
                UsageTrendRangeMenu(selection:$state.range,calendar:false,width:107,
                    label:L("曲线范围", "Chart range"),identifier:"usage-trends-range")
                Divider().frame(height:24)
                HStack(alignment:.firstTextBaseline,spacing:5) {
                    Text(state.periodTotalText).font(.system(size:24,weight:.semibold)).monospacedDigit()
                    Text("Token").font(.system(size:16,weight:.medium))
                }.fixedSize().accessibilityElement(children:.combine)
            }.frame(height:34)
            if state.chartSegments.isEmpty {
                Text(L("这段时间暂无记录", "No records in this range")).font(.system(size:13)).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,minHeight:228)
            } else {
                plot.frame(height:220).padding(.top,8)
            }
        }
    }
    private var plot: some View {
        Chart {
            ForEach(state.chartSegments,id:\.id) { segment in
                ForEach(segment.points) { point in
                    AreaMark(x:.value("Date",point.date),y:.value("Tokens",Double(point.tokens ?? 0)),series:.value("Segment",segment.id))
                        .foregroundStyle(LinearGradient(colors:[Color.blue.opacity(0.22),Color.blue.opacity(0.015)],startPoint:.top,endPoint:.bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x:.value("Date",point.date),y:.value("Tokens",Double(point.tokens ?? 0)),series:.value("Segment",segment.id))
                        .foregroundStyle(Color.blue).lineStyle(StrokeStyle(lineWidth:2)).interpolationMethod(.monotone)
                    PointMark(x:.value("Date",point.date),y:.value("Tokens",Double(point.tokens ?? 0)))
                        .foregroundStyle(Color.blue).symbolSize(28)
                        .accessibilityLabel(UsageTrendFormat.title(point,grouping:state.grouping))
                        .accessibilityValue(point.tokens.map { (point.isPartialPeriod ? "≥ " : "")+UsageTrendFormat.exactTokens($0)+" Token" } ?? "— Token")
                }
            }
            if let selected=activePoint {
                RuleMark(x:.value("Selected",selected.date)).foregroundStyle(Color.blue.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth:1,dash:[4,3])).accessibilityHidden(true)
                if let tokens=selected.tokens {
                PointMark(x:.value("Selected",selected.date),y:.value("Selected tokens",Double(tokens)))
                    .symbol {
                        Circle().fill(Color.blue).overlay(Circle().stroke(Color.white,lineWidth:1.3)).frame(width:16,height:16)
                    }
                    .annotation(position:.top,alignment:annotationAlignment,spacing:8) {
                        if hoveredPointID == nil {Text(UsageTrendFormat.value(selected)).font(.system(size:13,weight:.medium)).monospacedDigit().fixedSize()}
                    }.accessibilityHidden(true)
                }
            }
        }.chartXScale(domain:xDomain).chartYScale(domain:0...state.chartYMaximum)
            .chartXAxis {
                AxisMarks(values:axisDates) { value in
                    AxisGridLine(stroke:StrokeStyle(lineWidth:0.6,dash:[3,3])).foregroundStyle(Color.primary.opacity(0.085))
                    AxisValueLabel(anchor:.top,collisionResolution:.disabled) {
                        if let date=value.as(Date.self) { Text(UsageTrendFormat.date(date)).font(.system(size:12)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position:.leading,values:state.chartYTicks) { value in
                    AxisGridLine(stroke:StrokeStyle(lineWidth:0.6,dash:[3,3])).foregroundStyle(Color.primary.opacity(0.11))
                    AxisValueLabel {
                        if let tokens=value.as(Double.self) {
                            Text(UsageTrendFormat.chartTokens(tokens)).font(.system(size:12)).frame(width:54,alignment:.trailing)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    ZStack(alignment:.topLeading) {
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover {phase in
                            switch phase {
                            case .active(let location):
                                let bounds=geometry[proxy.plotAreaFrame]
                                guard location.x >= bounds.minX,location.x <= bounds.maxX,
                                      let date:Date=proxy.value(atX:location.x-bounds.minX) else {hoveredPointID=nil;return}
                                let nearest=state.chartPoints.min {abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))}
                                if hoveredPointID != nearest?.id {hoveredPointID=nearest?.id}
                            case .ended:hoveredPointID=nil
                            }
                        }
                        .gesture(DragGesture(minimumDistance:0).onChanged { value in
                            let bounds=geometry[proxy.plotAreaFrame]
                            guard bounds.contains(value.location),let date: Date=proxy.value(atX:value.location.x-bounds.minX) else { return }
                            state.selectNearestChartDate(date)
                        })
                    if hoveredPointID != nil,let point=activePoint,let x=proxy.position(forX:point.date) {
                        let bounds=geometry[proxy.plotAreaFrame]
                        let width:CGFloat=min(220,bounds.width)
                        VStack(alignment:.leading,spacing:3) {
                            Text(pointLabel).font(.system(size:11)).foregroundStyle(.secondary)
                            Text(point.tokens.map {(point.isPartialPeriod ? "≥ " : "")+UsageTrendFormat.exactTokens($0)+" Token"} ?? L("暂无记录", "No record")).font(.system(size:13,weight:.medium)).monospacedDigit()
                        }.padding(9).frame(width:width,alignment:.leading).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))
                            .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.12),lineWidth:0.7))
                            .position(x:min(max(bounds.minX+width/2,bounds.minX+x),bounds.maxX-width/2),y:bounds.minY+27)
                            .allowsHitTesting(false)
                    }
                    }
                }
            }
            .onChange(of:state.grouping) {_ in hoveredPointID=nil}
            .onChange(of:state.range) {_ in hoveredPointID=nil}
            .onDisappear {hoveredPointID=nil}
            .accessibilityIdentifier("usage-trends-plot")
            .accessibilityAction(named:L("上一条记录", "Previous record")) { selectAdjacent(-1) }
            .accessibilityAction(named:L("下一条记录", "Next record")) { selectAdjacent(1) }
    }
    private var xDomain: ClosedRange<Date> {
        let start=state.chartPoints.first?.date ?? state.data.rangeStartDate
        let end=state.chartPoints.last?.date ?? state.data.rangeEndDate
        return start...(end > start ? end : UsageTrendsPresentation.calendar.date(byAdding:.day,value:1,to:start) ?? start.addingTimeInterval(86_400))
    }
    private var axisDates: [Date] {
        let all=state.chartPoints
        guard let first=all.firstIndex(where:{ $0.tokens != nil }),let last=all.lastIndex(where:{ $0.tokens != nil }) else { return [] }
        let points=Array(all[first...last])
        let step=max(1,Int(ceil(Double(points.count-1)/10)))
        var indexes=Array(stride(from:0,to:points.count,by:step))
        let lastIndex=points.count-1
        if indexes.last != lastIndex {
            if let prior=indexes.last,lastIndex-prior < step { indexes.removeLast() }
            indexes.append(lastIndex)
        }
        return indexes.map { points[$0].date }
    }
    private var annotationAlignment: Alignment {
        guard let selected=activePoint else { return .center }
        let duration=xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        guard duration > 0 else { return .center }
        let fraction=selected.date.timeIntervalSince(xDomain.lowerBound)/duration
        return fraction < 0.18 ? .leading : fraction > 0.82 ? .trailing : .center
    }
    private func selectAdjacent(_ offset: Int) {
        let records=state.listPoints
        guard !records.isEmpty else { return }
        let index=records.firstIndex(where:{ $0.id == state.selectedID }) ?? records.count-1
        state.select(records[min(max(0,index+offset),records.count-1)])
    }
}

@MainActor private struct UsageTrendRecordedList: View {
    @ObservedObject var state: UsageTrendsPresentation
    @State private var expanded = false
    private var records: [UsageTrendPoint] { Array(state.listPoints.reversed()) }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Spacer()
                Button { expanded.toggle() } label: {
                    HStack(spacing:10) {
                        Text(expanded ? L("收起明细", "Hide details") : L("查看明细", "View details"))
                        Image(systemName:expanded ? "chevron.up" : "chevron.down").font(.system(size:12,weight:.medium)).accessibilityHidden(true)
                    }.font(.system(size:16,weight:.medium)).foregroundStyle(Color.blue)
                        .frame(minWidth:100,minHeight:30).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("usage-trends-details")
            }
            if expanded {
                if records.isEmpty {
                    Text(L("这段时间暂无记录", "No records in this range")).font(.system(size:13)).foregroundStyle(.secondary)
                        .frame(maxWidth:.infinity,minHeight:100)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing:0) {
                                ForEach(records) { point in
                                    UsageTrendListRow(point:point,grouping:state.grouping,maximum:state.maximum,
                                        selected:state.selectedID == point.id,action:{ state.select(point) }).id(point.id)
                                    Divider()
                                }
                            }
                        }.frame(height:CGFloat(min(records.count,8))*45)
                            .onAppear { scrollToSelection(proxy) }
                            .onChange(of:state.scrollSelectionRevision) { _ in scrollToSelection(proxy) }
                    }
                }
            }
        }
    }
    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let id=state.selectedID else { return }
        DispatchQueue.main.async { proxy.scrollTo(id,anchor:.center) }
    }
}

@MainActor private struct UsageTrendListRow: View {
    let point: UsageTrendPoint
    let grouping: UsageTrendGrouping
    let maximum: Int64
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action:action) {
            HStack(spacing:18) {
                Text(UsageTrendFormat.title(point,grouping:grouping)).font(.system(size:14)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width:180,alignment:.leading)
                GeometryReader { proxy in
                    ZStack(alignment:.leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        if let tokens=point.tokens,maximum > 0 {
                            Capsule().fill(Color.blue).frame(width:proxy.size.width*min(1,Double(tokens)/Double(maximum)))
                        }
                    }.frame(height:12).frame(maxHeight:.infinity)
                }.frame(maxWidth:.infinity).frame(height:20).accessibilityHidden(true)
                Text(UsageTrendFormat.value(point)).font(.system(size:14)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width:110,alignment:.trailing)
            }.padding(.horizontal,14).frame(height:44)
                .background(selected ? Color.blue.opacity(0.14) : hovered ? Color.primary.opacity(0.04) : .clear,in:RoundedRectangle(cornerRadius:6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered=$0 }
            .accessibilityLabel(UsageTrendFormat.title(point,grouping:grouping)+", "+accessibilityValue)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("usage-trend-day-"+point.id)
    }
    private var accessibilityValue: String {
        guard let tokens=point.tokens else { return "— Token" }
        let value=UsageTrendFormat.exactTokens(tokens)+" Token"
        return point.isPartial ? value+L("，仅合计已有记录", ", total of available records") : value
    }
}

@MainActor private struct UsageTrendCalendarCell: View {
    let cell: UsageTrendHeatmapCell
    let size: CGFloat
    let selected: Bool
    let interaction: UsageTrendInteraction
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action:action) {
            RoundedRectangle(cornerRadius:3).fill(color)
                .overlay(RoundedRectangle(cornerRadius:3).stroke(selected || hovered || focused ? Color.blue : .clear,lineWidth:1.2))
                .frame(width:size,height:size).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!cell.insideRange).focused($focused)
            .accessibilityHidden(!cell.insideRange).accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("usage-calendar-day-"+cell.day)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .anchorPreference(key:UsageTrendCellAnchors.self,value:.bounds) { cell.insideRange ? [cell.day:$0] : [:] }
            .onHover { active in
                guard cell.insideRange else { return }
                if hovered != active { hovered=active }
                interaction.hover(cell.day,active:active)
            }
            .onChange(of:focused) { interaction.focus(cell.day,active:$0) }
    }
    private var color: Color {
        guard cell.insideRange else { return .clear }
        guard let intensity=cell.intensity else { return Color.primary.opacity(scheme == .dark ? 0.11 : 0.045) }
        return intensity == 0 ? Color.primary.opacity(scheme == .dark ? 0.22 : 0.13) : Color.blue.opacity([0,0.38,0.58,0.78,1][min(4,intensity)])
    }
    private var accessibilityLabel: String {
        UsageTrendFormat.date(cell.date,year:true)+", "+(cell.tokens.map { UsageTrendFormat.exactTokens($0)+" Token" } ?? L("暂无记录", "No recorded usage"))
    }
}

@MainActor private struct UsageTrendTooltipOverlay: View {
    @ObservedObject var interaction: UsageTrendInteraction
    let map: UsageTrendHeatmap
    let anchors: [String:Anchor<CGRect>]
    let framesChanged: (([String:CGRect]) -> Void)?
    var body: some View {
        GeometryReader { proxy in
            if let framesChanged {
                let frames=anchors.mapValues { proxy[$0] }
                Color.clear.onAppear { framesChanged(frames) }.onChange(of:frames) { framesChanged($0) }
            }
            if let day=interaction.activeDay,let anchor=anchors[day],
               let cell=map.columns.lazy.flatMap(\.cells).first(where:{ $0.day == day && $0.insideRange }),
               proxy[anchor].intersects(CGRect(origin:.zero,size:proxy.size)) {
                let tokenText=cell.tokens.map { UsageTrendFormat.exactTokens($0)+" Token" } ?? "— Token"
                let dateText=UsageTrendFormat.date(cell.date,year:true)
                let textWidth=(tokenText as NSString).size(withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:13,weight:.regular)]).width
                let dateWidth=(dateText as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13)]).width
                let bounds=CGRect(origin:.zero,size:proxy.size)
                let frame=UsageTrendTooltipPlacement.frame(anchor:proxy[anchor],size:CGSize(width:max(140,min(300,max(textWidth,dateWidth)+24)),height:54),bounds:bounds)
                VStack(alignment:.leading,spacing:4) {
                    Text(dateText)
                    Text(tokenText).monospacedDigit()
                }.font(.system(size:13)).lineLimit(1).minimumScaleFactor(0.85)
                    .frame(width:max(0,frame.width-24),height:max(0,frame.height-16),alignment:.leading).padding(.horizontal,12).padding(.vertical,8)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.12),lineWidth:0.6))
                    .shadow(color:.black.opacity(0.18),radius:6,y:3)
                    .position(x:frame.midX,y:frame.midY)
                let above=frame.maxY <= proxy[anchor].minY
                Image(systemName:above ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                    .font(.system(size:9)).foregroundStyle(Color(nsColor:.windowBackgroundColor))
                    .position(x:min(max(proxy[anchor].midX,frame.minX+12),frame.maxX-12),y:above ? frame.maxY+2 : frame.minY-2)
                    .accessibilityHidden(true)
            }
        }.allowsHitTesting(false)
    }
}
