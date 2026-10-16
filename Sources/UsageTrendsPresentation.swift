import AppKit
import Combine

enum UsageSubpage: String, CaseIterable, Identifiable {
    case display, trends, forecast
    var id: Self { self }
    var title: String {
        switch self {
        case .display: return L("顶栏助手", "Menu bar assistant")
        case .trends: return L("用量趋势", "Usage trends")
        case .forecast: return L("用量预测", "Usage forecast")
        }
    }
}

@MainActor final class UsageNavigationState: ObservableObject {
    @Published var page: UsageSubpage = .display
    private var initialized = false
    func configure(_ initial: UsageSubpage) {
        guard !initialized else { return }
        initialized=true;page=initial
    }
}

// Observe statistics and the civil day only; quota/message ticks must not
// rebuild the annual calendar or the date list.
@MainActor final class UsageTrendsPresentation: ObservableObject {
    @Published private(set) var statistics: UsageStatistics?
    @Published private(set) var updated: Date?
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false
    @Published private(set) var data: UsageTrends
    @Published private(set) var calendarData: UsageTrendHeatmap
    @Published private(set) var points: [UsageTrendPoint]
    @Published private(set) var chartSegments: [UsageTrendChartSegment]
    @Published private(set) var chartYMaximum: Double
    @Published private(set) var chartYTicks: [Double]
    private(set) var maximum: Int64
    private(set) var calendarRevision = 0
    @Published var calendarRange: UsageTrendRange = .year { didSet { if oldValue != calendarRange { rebuildCalendar() } } }
    @Published var range: UsageTrendRange = .days30 { didSet { if oldValue != range { data=data.selectingRange(range);rebuildPoints();scrollSelectionRevision += 1 } } }
    @Published var grouping: UsageTrendGrouping = .daily { didSet { if oldValue != grouping { rebuildPoints();scrollSelectionRevision += 1 } } }
    @Published private(set) var selectedID: String?
    @Published private(set) var scrollSelectionRevision = 0
    @Published private(set) var selectedDay: String?
    private var annualDays: [UsageTrendPoint]
    let model: AppModel
    let sample: Bool
    private(set) var now: Date
    private var clockKey: String
    private var subscriptions = Set<AnyCancellable>()
    init(model: AppModel) {
        self.model = model;sample = model.isDemonstrating;now = model.now
        statistics = model.statistics;updated = model.statisticsUpdated;error = model.statisticsError
        refreshing = model.statisticsRefreshing;clockKey = Self.key(model.now)
        let initial=UsageTrends(statistics:model.statistics,now:model.now,calendar:Self.calendar)
        let initialPoints=initial.points(for:.daily)
        let initialMaximum=initialPoints.compactMap(\.tokens).max() ?? 0
        let scale=Self.chartScale(maximum:initialMaximum)
        data=initial;calendarData=initial.heatmap;points=initialPoints;maximum=initialMaximum
        chartSegments=initial.chartSegments(for:.daily);chartYMaximum=scale.maximum;chartYTicks=scale.ticks
        annualDays=Self.annualPoints(initial)
        selectedID = initialPoints.last(where:{ $0.tokens != nil })?.id
        selectedDay=selectedID
        model.$statistics.removeDuplicates().sink { [weak self] value in
            guard let self,self.statistics != value else { return }
            self.statistics = value;self.rebuild()
        }.store(in:&subscriptions)
        model.$statisticsUpdated.removeDuplicates().sink { [weak self] in self?.updated = $0 }.store(in:&subscriptions)
        model.$statisticsError.removeDuplicates().sink { [weak self] in self?.error = $0 }.store(in:&subscriptions)
        model.$statisticsRefreshing.removeDuplicates().sink { [weak self] in self?.refreshing = $0 }.store(in:&subscriptions)
        model.$now.sink { [weak self] value in
            guard let self else { return }
            let key = Self.key(value)
            guard key != self.clockKey else { return }
            self.clockKey = key;self.now = value;self.rebuild()
        }.store(in:&subscriptions)
    }
    static var calendar: Calendar {
        var calendar = Calendar(identifier:.gregorian)
        calendar.locale = .autoupdatingCurrent;calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        calendar.minimumDaysInFirstWeek = Calendar.autoupdatingCurrent.minimumDaysInFirstWeek
        return calendar
    }
    private static func key(_ date: Date) -> String {
        let calendar = Self.calendar
        let day = calendar.dateComponents([.year,.month,.day],from:date)
        return "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)|\(calendar.timeZone.identifier)|\(calendar.timeZone.secondsFromGMT(for:date))|\(Locale.autoupdatingCurrent.identifier)|\(calendar.firstWeekday)|\(calendar.minimumDaysInFirstWeek)"
    }
    var selected: UsageTrendPoint? { points.first(where:{ $0.id == selectedID }) }
    var chartPoints: [UsageTrendPoint] { points }
    var periodTotal: Int64? { data.knownTotal }
    var periodTotalPartial: Bool { data.coverage.isPartial }
    var periodTotalOverflowed: Bool { data.totalOverflowed }
    var periodTotalText: String {
        guard let periodTotal else { return "—" }
        return (periodTotalPartial ? "≥ " : "")+UsageTrendFormat.tokens(periodTotal)
    }
    var listPoints: [UsageTrendPoint] { points.filter { $0.tokens != nil } }
    var selectedDaily: UsageTrendPoint? { annualDays.first(where:{ $0.day == selectedDay }) }
    var selectedSourceDate: Date? { selectedDaily?.date }
    var dailyChartPoints: [UsageTrendPoint] {
        guard let selectedDaily else { return [] }
        return Array(annualDays.filter { $0.date <= selectedDaily.date }.suffix(7))
    }
    var sevenDayAverage: Int64? {
        let days=dailyChartPoints
        guard days.count == 7 else { return nil }
        var total: Int64=0
        for day in days {
            guard let tokens=day.tokens else { return nil }
            let next=total.addingReportingOverflow(tokens)
            guard !next.overflow else { return nil }
            total=next.partialValue
        }
        return total/7
    }
    func select(_ point: UsageTrendPoint) {
        guard let current=points.first(where:{ $0.id == point.id }) else { return }
        let sourceDay = grouping == .weekly
            ? annualDays.last(where:{ $0.date >= current.startDate && $0.date <= current.endDate && $0.tokens != nil })?.day ?? current.day
            : current.day
        setSelection(point:current,sourceDay:sourceDay)
    }
    func selectDate(_ date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let source=annualDays.first(where:{ $0.date == date }) else { return }
        if date < data.rangeStartDate { range = .year }
        if let point=point(for:source.date) { setSelection(point:point,sourceDay:source.day) }
    }
    @discardableResult func selectNearestChartDate(_ date: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        let known=points.filter { $0.tokens != nil }
        guard let first=known.first,let last=known.last else { return false }
        let clamped=min(last.date,max(first.date,date))
        guard let nearest=known.min(by:{ abs($0.date.timeIntervalSince(clamped)) < abs($1.date.timeIntervalSince(clamped)) }) else { return false }
        select(nearest);return true
    }
    func refresh() { model.refreshUsageTrends() }
    private func rebuild() {
        data = UsageTrends(statistics:statistics,range:range,now:now,calendar:Self.calendar)
        annualDays=Self.annualPoints(data)
        rebuildCalendar()
        rebuildPoints()
    }
    private func rebuildCalendar() {
        calendarData=data.heatmap(for:calendarRange);calendarRevision += 1
    }
    private static func annualPoints(_ data: UsageTrends) -> [UsageTrendPoint] {
        data.heatmap.columns.flatMap(\.cells).filter(\.insideRange).map { cell in
            UsageTrendPoint(day:cell.day,date:cell.date,startDate:cell.date,endDate:cell.date,
                periodStartDate:cell.date,periodEndDate:cell.date,tokens:cell.tokens,
                knownDays:cell.tokens == nil ? 0 : 1,expectedDays:1,overflowed:false,isCurrentWeek:false,isPartialPeriod:false)
        }.sorted { $0.date < $1.date }
    }
    private func rebuildPoints() {
        let value=data.points(for:grouping)
        maximum=value.compactMap(\.tokens).max() ?? 0;points=value
        chartSegments=data.chartSegments(for:grouping)
        let scale=Self.chartScale(maximum:maximum)
        chartYMaximum=scale.maximum;chartYTicks=scale.ticks
        retainSelection()
    }
    private func setSelection(point: UsageTrendPoint,sourceDay: String) {
        guard selectedID != point.id || selectedDay != sourceDay else { return }
        selectedID=point.id;selectedDay=sourceDay;scrollSelectionRevision += 1
    }
    private func point(for sourceDate: Date) -> UsageTrendPoint? {
        if grouping == .cumulative { return points.first(where:{ $0.date == sourceDate }) }
        return points.first(where:{ $0.startDate <= sourceDate && sourceDate <= $0.endDate })
    }
    private static func chartScale(maximum: Int64) -> (maximum: Double,ticks: [Double]) {
        guard maximum > 0 else { return (1,[0,1]) }
        let raw=Double(maximum)*1.12
        let magnitude=pow(10,floor(log10(raw)))
        let normalized=raw/magnitude
        let step=[1.0,2,2.5,5,10].first(where:{ $0 >= normalized }) ?? 10
        let upper=max(1,ceil(step*magnitude)),tickStep=max(1,upper/4)
        return (upper,Array(stride(from:0.0,through:upper,by:tickStep)))
    }
    private func retainSelection() {
        if let selectedDay,let row=data.dailyRows.first(where:{ $0.day == selectedDay }),
           let point=point(for:row.date) {
            selectedID=point.id;return
        }
        if let day=annualDays.last(where:{ $0.date >= data.rangeStartDate && $0.date <= data.rangeEndDate && $0.tokens != nil }) {
            selectedDay=day.day
            selectedID=point(for:day.date)?.id
        } else {
            selectedID=nil;selectedDay=nil
        }
    }
}

@MainActor enum UsageTrendFormat {
    private static var context = ""
    private static var dateFormatters = [String:DateFormatter]()
    private static var tokenFormatter: NumberFormatter?
    private static var compactFormatter: NumberFormatter?
    private static func formatter(_ template: String) -> DateFormatter {
        let key=Locale.autoupdatingCurrent.identifier+"|"+TimeZone.autoupdatingCurrent.identifier
        if key != context { context=key;dateFormatters.removeAll();tokenFormatter=nil;compactFormatter=nil }
        if let cached=dateFormatters[template] { return cached }
        let result=DateFormatter();result.locale = .autoupdatingCurrent
        result.calendar=UsageTrendsPresentation.calendar;result.timeZone = .autoupdatingCurrent
        result.setLocalizedDateFormatFromTemplate(template);dateFormatters[template]=result
        return result
    }
    static func date(_ date: Date,year: Bool = false) -> String {
        formatter(year ? "yMMMd" : "MMMd").string(from:date)
    }
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium;formatter.timeStyle = .short
        return formatter.string(from:date)+" "+(formatter.timeZone.abbreviation(for:date) ?? formatter.timeZone.identifier)
    }
    static func title(_ point: UsageTrendPoint,grouping: UsageTrendGrouping) -> String {
        if grouping == .weekly { return date(point.startDate)+" – "+date(point.endDate) }
        return date(point.date)
    }
    static func duration(_ seconds: Int64?) -> String {
        guard let seconds else { return "—" }
        if !AppLanguage.chinese { return StatisticsFormat.duration(seconds) }
        if seconds < 60 { return "不足1分钟" }
        let minutes = seconds/60
        if minutes < 60 { return "\(minutes)分钟" }
        return "\(minutes/60)小时\(minutes%60)分"
    }
    static func exactTokens(_ tokens: Int64) -> String {
        _=formatter("MMMd")
        if tokenFormatter == nil {
            let result=NumberFormatter();result.locale = .autoupdatingCurrent
            result.numberStyle = .decimal;result.maximumFractionDigits = 0;result.groupingSeparator=",";tokenFormatter=result
        }
        return tokenFormatter?.string(from:NSNumber(value:tokens)) ?? String(tokens)
    }
    static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        _=formatter("MMMd")
        if compactFormatter == nil {
            let result=NumberFormatter();result.locale = .autoupdatingCurrent
            result.numberStyle = .decimal;result.maximumFractionDigits=2;result.usesGroupingSeparator=false;compactFormatter=result
        }
        let units: [(Double,String)] = AppLanguage.chinese ? [(100_000_000,"亿"),(10_000,"万")] : [(1_000_000_000,"B"),(1_000_000,"M"),(1_000,"K")]
        for (scale,suffix) in units where Double(value) >= scale {
            return (compactFormatter?.string(from:NSNumber(value:Double(value)/scale)) ?? "—")+suffix
        }
        return exactTokens(value)
    }
    static func roundedTokens(_ value: Int64) -> String {
        let scales: [(Double,String)] = AppLanguage.chinese ? [(100_000_000,"亿"),(10_000,"万")] : [(1_000_000_000,"B"),(1_000_000,"M"),(1_000,"K")]
        for (scale,suffix) in scales where Double(value) >= scale {
            return String(Int64((Double(value)/scale).rounded()))+suffix
        }
        return exactTokens(value)
    }
    static func chartTokens(_ value: Double) -> String {
        guard value.isFinite,value >= 0 else { return "—" }
        _=formatter("MMMd")
        if compactFormatter == nil {
            let result=NumberFormatter();result.locale = .autoupdatingCurrent
            result.numberStyle = .decimal;result.maximumFractionDigits=2;result.usesGroupingSeparator=false;compactFormatter=result
        }
        let units: [(Double,String)] = AppLanguage.chinese ? [(100_000_000,"亿"),(10_000,"万")] : [(1_000_000_000,"B"),(1_000_000,"M"),(1_000,"K")]
        for (scale,suffix) in units where value >= scale {
            return (compactFormatter?.string(from:NSNumber(value:value/scale)) ?? "—")+suffix
        }
        return compactFormatter?.string(from:NSNumber(value:value)) ?? "—"
    }
    static func weekday(_ value: Int) -> String { formatter("MMM").shortWeekdaySymbols[max(0,min(6,value-1))] }
    static func month(_ date: Date,year: Bool) -> String { formatter(year ? "yMMM" : "MMM").string(from:date) }
    static func value(_ point: UsageTrendPoint) -> String {
        point.overflowed ? "—" : point.tokens.map { (point.isPartial ? "≥ " : "")+tokens($0) } ?? "—"
    }
}
