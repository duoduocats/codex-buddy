import SwiftUI
import Charts

@MainActor final class UsageChartRange: ObservableObject {
    @Published var days = 14
}

@MainActor private final class ChartSelection: ObservableObject {
    @Published var hovered: String?
    func update(_ value:String?) {
        if hovered != value { hovered = value }
    }
}

struct DailyUsageChart: View {
    var statistics: UsageStatistics?
    var refreshing: Bool
    var now: Date
    @Binding var days: Int
    var exporting = false
    var allowsSharing = false
    var sharePresentationChanged: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    private var color: Color { scheme == .dark ? Color(red:0.64,green:0.54,blue:1) : .blue }
    private var points: [DailyTokenUsage] { statistics?.history(days:days,now:now) ?? [] }
    private var domain: ClosedRange<Date> {
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
        let end = calendar.startOfDay(for:now)
        return calendar.date(byAdding:.day,value:1-days,to:end)!...end
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(L("每日 Token 使用量", "Daily token usage")).font(.system(size:13,weight:.semibold))
                Spacer()
                if allowsSharing && !exporting {
                    UsageShareButton(statistics:statistics,days:days,now:now,dark:scheme == .dark,presentationChanged:sharePresentationChanged)
                        .frame(width:20,height:20)
                }
                if exporting {
                    Text(L("近\(days)天", "Last \(days) days")).font(.system(size:11)).foregroundStyle(.secondary)
                } else {
                    Picker(L("时间范围", "Date range"),selection:$days) {
                        ForEach([7,14,30],id:\.self) { days in Text(L("近\(days)天", "Last \(days) days")).tag(days) }
                    }.labelsHidden().pickerStyle(.menu).font(.system(size:11)).fixedSize()
                }
            }
            if points.isEmpty {
                Text(refreshing ? L("读取中…", "Loading…") : L("暂无每日用量", "Daily usage is unavailable"))
                    .font(.system(size:12)).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity).frame(height:112)
            } else {
                let data = points
                Chart {
                    ForEach(data) { point in
                        let date = point.date
                        AreaMark(x:.value(L("日期", "Date"),date),
                            yStart:.value("Baseline",0),yEnd:.value("Tokens",Double(point.tokens)))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors:[color.opacity(0.16),color.opacity(0.01)],startPoint:.top,endPoint:.bottom))
                        LineMark(x:.value(L("日期", "Date"),date),
                            y:.value("Tokens",Double(point.tokens)))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round))
                        PointMark(x:.value(L("日期", "Date"),date),y:.value("Tokens",Double(point.tokens)))
                            .foregroundStyle(color).symbolSize(6)
                            .accessibilityLabel(point.day)
                            .accessibilityValue(StatisticsFormat.tokens(point.tokens))
                    }
                }
                .chartXScale(domain:domain)
                .chartYScale(domain:0...max(2,Double(data.map { $0.tokens }.max() ?? 1)*1.12))
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values:[domain.lowerBound,Calendar.current.date(byAdding:.day,value:-(days/2),to:domain.upperBound)!,domain.upperBound]) { value in
                        AxisValueLabel(format:.dateTime.month(.defaultDigits).day(),
                            anchor:value.as(Date.self) == domain.upperBound ? .topTrailing : value.as(Date.self) == domain.lowerBound ? .topLeading : .top,
                            collisionResolution:.disabled)
                    }
                }
                .chartYAxis {
                    AxisMarks(position:.leading,values:.automatic(desiredCount:3)) { value in
                        AxisGridLine(stroke:StrokeStyle(lineWidth:0.5,dash:[3,3])).foregroundStyle(.secondary.opacity(0.25))
                        AxisValueLabel(anchor:.trailing) {
                            if let number = value.as(Double.self), number.isFinite, number >= 0, number < 9_223_372_036_854_775_808 {
                                Text(StatisticsFormat.tokens(Int64(number))).font(.system(size:9))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    if !exporting {
                        UsageChartOverlay(data:data,proxy:proxy,color:color,days:days)
                    }
                }
                .frame(height:112)
            }
        }.transaction { $0.animation = nil }
    }
}

// Keep hover state below Chart so pointer movement updates only the overlay.
// Rebuilding marks and axes for every selected day wastes layout work.
private struct UsageChartOverlay: View {
    let data: [DailyTokenUsage]
    private let dates: [Date]
    let proxy: ChartProxy
    let color: Color
    let days: Int
    @StateObject private var selection = ChartSelection()
    init(data:[DailyTokenUsage],proxy:ChartProxy,color:Color,days:Int) {
        self.data = data;self.dates = data.map(\.date)
        self.proxy = proxy;self.color = color;self.days = days
    }
    var body: some View {
        GeometryReader { geometry in
            let plot = geometry[proxy.plotAreaFrame]
            ZStack(alignment:.topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard plot.contains(location),
                                  let date: Date = proxy.value(atX:location.x-plot.minX) else {
                                selection.update(nil);return
                            }
                            let index = dates.indices.min {
                                abs(dates[$0].timeIntervalSince(date)) < abs(dates[$1].timeIntervalSince(date))
                            }
                            selection.update(index.map { data[$0].id })
                        case .ended: selection.update(nil)
                        }
                    }
                if let index = data.firstIndex(where:{ $0.id == selection.hovered }),
                   let x = proxy.position(forX:dates[index]),
                   let y = proxy.position(forY:Double(data[index].tokens)) {
                    let point = data[index]
                    Path { path in
                        path.move(to:CGPoint(x:plot.minX+x,y:plot.minY))
                        path.addLine(to:CGPoint(x:plot.minX+x,y:plot.maxY))
                    }.stroke(Color.secondary.opacity(0.4),lineWidth:1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    let diameter: CGFloat = sqrt(120 / .pi)
                    Circle().fill(color).frame(width:diameter,height:diameter)
                        .offset(x:plot.minX+x-diameter/2,y:plot.minY+y-diameter/2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    UsageTooltipLayout(anchor:CGPoint(x:x,y:4)) {
                        Text("\(point.day) · \(StatisticsFormat.tokens(point.tokens))")
                            .font(.system(size:10)).padding(5)
                            .fixedSize(horizontal:false,vertical:true)
                            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:5))
                    }.frame(width:plot.width,height:plot.height)
                        .offset(x:plot.minX,y:plot.minY)
                        .allowsHitTesting(false)
                }
            }
        }.onChange(of:days) { _ in selection.update(nil) }
    }
}
