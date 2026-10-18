import Foundation

enum UsageTrendRange: String, CaseIterable, Identifiable {
    case days30, days90, year
    var id: String { rawValue }
}

enum UsageTrendGrouping: String, CaseIterable, Identifiable {
    case daily, weekly, cumulative
    var id: String { rawValue }
}

enum UsageTrendHistoryState: Equatable {
    case unavailable, empty, outsideRange, available
}

struct UsageTrendCoverage: Equatable {
    let expectedDays: Int
    let knownDays: Int
    var missingDays: Int { expectedDays - knownDays }
    var isPartial: Bool { missingDays > 0 }
}

struct UsageTrendDay: Equatable, Identifiable {
    let day: String
    let date: Date
    let tokens: Int64?
    var id: String { day }
}

struct UsageTrendPoint: Equatable, Identifiable {
    let day: String
    let date: Date
    // These bounds describe the dates included in this display point.
    let startDate: Date
    let endDate: Date
    // Weekly natural bounds can extend beyond the selected display period.
    let periodStartDate: Date
    let periodEndDate: Date
    let tokens: Int64?
    let knownDays: Int
    let expectedDays: Int
    let overflowed: Bool
    let isCurrentWeek: Bool
    let isPartialPeriod: Bool
    var id: String { day }
    var missingDays: Int { expectedDays - knownDays }
    var isPartial: Bool { missingDays > 0 }
}

struct UsageTrendChartSegment: Equatable, Identifiable {
    let id: Int
    let points: [UsageTrendPoint]
}

// Cached stored coordinates let modern Charts draw a whole series at once.
struct UsageTrendRenderPoint:Equatable {
    let date:Date
    let tokens:Double
    let series:Int
}
struct UsageTrendRenderSegment:Equatable,Identifiable {
    let id:Int
    let points:[UsageTrendRenderPoint]
    init(_ segment:UsageTrendChartSegment) {
        id=segment.id
        points=segment.points.map {.init(date:$0.date,tokens:Double($0.tokens ?? 0),series:segment.id)}
    }
}

struct UsageTrendHeatmapCell: Equatable, Identifiable {
    let day: String
    let date: Date
    let weekday: Int
    let tokens: Int64?
    let insideRange: Bool
    let isFuture: Bool
    // nil is missing/padding, 0 is a reported zero, positive bands are 1...4.
    let intensity: Int?
    var id: String { day }
}

struct UsageTrendHeatmapColumn: Equatable, Identifiable {
    let day: String
    let index: Int
    let startDate: Date
    let endDate: Date
    let cells: [UsageTrendHeatmapCell]
    var id: String { day }
}

struct UsageTrendMonthTick: Equatable, Identifiable {
    let column: Int
    let date: Date
    let year: Int
    let month: Int
    var id: String { "\(year)-\(month)" }
}

struct UsageTrendHeatmap: Equatable {
    let startDate: Date
    let endDate: Date
    let weekdayOrder: [Int]
    let columns: [UsageTrendHeatmapColumn]
    let monthTicks: [UsageTrendMonthTick]
    let coverage: UsageTrendCoverage
    let maximumTokens: Int64?
}

// One calculation supplies the chart, list and annual calendar. Source keys are
// Gregorian civil dates: using the display time zone never claims a source zone.
struct UsageTrends: Equatable {
    let range: UsageTrendRange
    let rangeStartDate: Date
    let rangeEndDate: Date
    let dailyRows: [UsageTrendDay]
    let weeklyRows: [UsageTrendPoint]
    let cumulativeRows: [UsageTrendPoint]
    let coverage: UsageTrendCoverage
    // Sum of returned buckets in the selected period, never lifetimeTokens.
    let knownTotal: Int64?
    let totalOverflowed: Bool
    let historyState: UsageTrendHistoryState
    let heatmap: UsageTrendHeatmap
    private let annualRows: [UsageTrendDay]
    private let calendar: Calendar
    private let sourceAvailability: UsageTrendHistoryState

    init(statistics: UsageStatistics?, range: UsageTrendRange = .days30,
         now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        self.range = range
        let today = calendar.startOfDay(for: now)
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        // Exclude the anniversary, include today; leap years retain their day.
        let anniversary = civil.date(byAdding: .year, value: -1, to: today) ?? today
        let annualStart = civil.date(byAdding: .day, value: 1, to: anniversary) ?? anniversary
        let start: Date
        switch range {
        case .days30: start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .days90: start = calendar.date(byAdding: .day, value: -89, to: today) ?? today
        case .year: start = annualStart
        }
        rangeStartDate = start
        rangeEndDate = today
        let annualStartKey = Self.key(for: annualStart, civil: civil)
        let endKey = Self.key(for: today, civil: civil)
        var values = [String: Int64]()
        var duplicates = Set<String>()
        // Do not retain or parse dates outside the displayable annual window.
        for bucket in statistics?.daily ?? [] {
            guard bucket.tokens >= 0, bucket.day >= annualStartKey, bucket.day <= endKey,
                  Self.parse(bucket.day, civil: civil) != nil else { continue }
            if values.updateValue(bucket.tokens, forKey: bucket.day) != nil {
                duplicates.insert(bucket.day)
            }
        }
        for day in duplicates { values.removeValue(forKey: day) }
        let annualRows = Self.days(from: annualStart, through: today, calendar: calendar, civil: civil, values: values)
        self.annualRows = annualRows
        self.calendar = calendar
        sourceAvailability = statistics?.daily == nil ? .unavailable : statistics?.daily?.isEmpty == true ? .empty : .available
        dailyRows = annualRows.filter { $0.date >= start }
        coverage = UsageTrendCoverage(expectedDays: dailyRows.count, knownDays: dailyRows.filter { $0.tokens != nil }.count)
        let total = Self.sum(dailyRows)
        knownTotal = total.value
        totalOverflowed = total.overflowed
        if statistics?.daily == nil {
            historyState = .unavailable
        } else if statistics?.daily?.isEmpty == true {
            historyState = .empty
        } else if coverage.knownDays == 0 {
            historyState = .outsideRange
        } else {
            historyState = .available
        }
        weeklyRows = Self.weeks(dailyRows, today: today, calendar: calendar, civil: civil)
        cumulativeRows = Self.cumulative(dailyRows)
        heatmap = Self.calendarGrid(annualRows, today: today, calendar: calendar, civil: civil)
    }

    // Reuse the sanitized civil-day rows and annual grid when only the curve
    // range changes. This never reparses source buckets or rebuilds the grid.
    func selectingRange(_ range: UsageTrendRange) -> UsageTrends {
        range == self.range ? self : UsageTrends(base: self, range: range)
    }

    func heatmap(for range: UsageTrendRange) -> UsageTrendHeatmap {
        guard range != .year else { return heatmap }
        let start = rangeStart(for: range)
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        return Self.calendarGrid(annualRows.filter { $0.date >= start }, today: rangeEndDate, calendar: calendar, civil: civil)
    }

    // Rendering fills missing buckets while the sanitized source remains optional.
    func chartPoints(for grouping:UsageTrendGrouping) -> [UsageTrendPoint] {
        let raw=points(for:grouping)
        guard historyState != .unavailable else {return raw}
        var running:Int64=0
        return raw.map { point in
            if let value=point.tokens {running=value;return point}
            guard !point.overflowed else {return point}
            let value=grouping == .cumulative ? running : 0
            return UsageTrendPoint(day:point.day,date:point.date,startDate:point.startDate,endDate:point.endDate,
                periodStartDate:point.periodStartDate,periodEndDate:point.periodEndDate,tokens:value,
                knownDays:point.knownDays,expectedDays:point.expectedDays,overflowed:point.overflowed,
                isCurrentWeek:point.isCurrentWeek,isPartialPeriod:point.isPartialPeriod)
        }
    }

    func chartSegments(for grouping: UsageTrendGrouping) -> [UsageTrendChartSegment] {
        var segments = [[UsageTrendPoint]]()
        var current = [UsageTrendPoint]()
        for point in chartPoints(for: grouping) {
            if point.tokens == nil {
                if !current.isEmpty { segments.append(current); current = [] }
            } else { current.append(point) }
        }
        if !current.isEmpty { segments.append(current) }
        return segments.enumerated().map { UsageTrendChartSegment(id: $0.offset, points: $0.element) }
    }

    private init(base: UsageTrends, range: UsageTrendRange) {
        self.range = range
        annualRows = base.annualRows; calendar = base.calendar; sourceAvailability = base.sourceAvailability
        heatmap = base.heatmap; rangeEndDate = base.rangeEndDate
        let start = base.rangeStart(for: range)
        rangeStartDate = start
        let rows = base.annualRows.filter { $0.date >= start }
        dailyRows = rows
        coverage = UsageTrendCoverage(expectedDays: rows.count, knownDays: rows.filter { $0.tokens != nil }.count)
        let total = Self.sum(rows); knownTotal = total.value; totalOverflowed = total.overflowed
        historyState = sourceAvailability == .available && coverage.knownDays == 0 ? .outsideRange : sourceAvailability
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        weeklyRows = Self.weeks(rows, today: rangeEndDate, calendar: calendar, civil: civil)
        cumulativeRows = Self.cumulative(rows)
    }

    private func rangeStart(for range: UsageTrendRange) -> Date {
        switch range {
        case .days30: return calendar.date(byAdding: .day, value: -29, to: rangeEndDate) ?? rangeEndDate
        case .days90: return calendar.date(byAdding: .day, value: -89, to: rangeEndDate) ?? rangeEndDate
        case .year: return annualRows.first?.date ?? rangeEndDate
        }
    }

    func points(for grouping: UsageTrendGrouping) -> [UsageTrendPoint] {
        switch grouping {
        case .daily:
            return dailyRows.map {
                UsageTrendPoint(day: $0.day, date: $0.date, startDate: $0.date, endDate: $0.date,
                                periodStartDate: $0.date, periodEndDate: $0.date, tokens: $0.tokens,
                                knownDays: $0.tokens == nil ? 0 : 1, expectedDays: 1,
                                overflowed: false, isCurrentWeek: false, isPartialPeriod: false)
            }
        case .weekly: return weeklyRows
        case .cumulative: return cumulativeRows
        }
    }

    private static func key(for date: Date, civil: Calendar) -> String {
        let parts = civil.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func parse(_ day: String, civil: Calendar) -> Date? {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else { return nil }
        func number(_ positions: Range<Int>) -> Int {
            positions.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
        }
        let year = number(0..<4), month = number(5..<7), dateDay = number(8..<10)
        guard year > 0, (1...12).contains(month), (1...31).contains(dateDay),
              let date = civil.date(from: DateComponents(year: year, month: month, day: dateDay)),
              key(for: date, civil: civil) == day else { return nil }
        return civil.startOfDay(for: date)
    }

    private static func days(from start: Date, through end: Date, calendar: Calendar,
                             civil: Calendar, values: [String: Int64]) -> [UsageTrendDay] {
        var result = [UsageTrendDay]()
        var date = start
        while date <= end {
            let day = key(for: date, civil: civil)
            result.append(UsageTrendDay(day: day, date: date, tokens: values[day]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        return result
    }

    private static func sum(_ rows: [UsageTrendDay]) -> (value: Int64?, overflowed: Bool) {
        var sum: Int64 = 0
        var hasValue = false
        for row in rows {
            guard let tokens = row.tokens else { continue }
            hasValue = true
            let result = sum.addingReportingOverflow(tokens)
            guard !result.overflow else { return (nil, true) }
            sum = result.partialValue
        }
        return (hasValue ? sum : nil, false)
    }

    private static func weekStart(for date: Date, calendar: Calendar) -> Date {
        if let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start {
            return calendar.startOfDay(for: start)
        }
        let offset = (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: date) ?? date
    }

    private static func weeks(_ rows: [UsageTrendDay], today: Date, calendar: Calendar,
                              civil: Calendar) -> [UsageTrendPoint] {
        var groups = [[UsageTrendDay]]()
        var previousStart: Date?
        for row in rows {
            let start = weekStart(for: row.date, calendar: calendar)
            if previousStart != start { groups.append([]); previousStart = start }
            groups[groups.count - 1].append(row)
        }
        let currentStart = weekStart(for: today, calendar: calendar)
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let start = weekStart(for: first.date, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            let total = sum(group)
            return UsageTrendPoint(day: key(for: last.date, civil: civil), date: last.date,
                                   startDate: first.date, endDate: last.date, periodStartDate: start, periodEndDate: end,
                                   tokens: total.value, knownDays: group.filter { $0.tokens != nil }.count,
                                   expectedDays: group.count, overflowed: total.overflowed,
                                   isCurrentWeek: start == currentStart,
                                   isPartialPeriod: first.date != start || last.date != end)
        }
    }

    private static func cumulative(_ rows: [UsageTrendDay]) -> [UsageTrendPoint] {
        guard let first = rows.first else { return [] }
        var sum: Int64 = 0, known = 0
        var overflowed = false
        return rows.enumerated().map { index, row in
            if let tokens = row.tokens {
                known += 1
                if !overflowed {
                    let result = sum.addingReportingOverflow(tokens)
                    overflowed = result.overflow
                    if !overflowed { sum = result.partialValue }
                }
            }
            // Unknown dates stay unknown. Cumulative charts connect the known
            // running totals without inventing intermediate daily usage.
            return UsageTrendPoint(day: row.day, date: row.date, startDate: first.date, endDate: row.date,
                                   periodStartDate: first.date, periodEndDate: row.date,
                                   tokens: row.tokens == nil || overflowed ? nil : sum,
                                   knownDays: known, expectedDays: index + 1, overflowed: overflowed,
                                   isCurrentWeek: false, isPartialPeriod: false)
        }
    }

    private static func calendarGrid(_ rows: [UsageTrendDay], today: Date, calendar: Calendar,
                                     civil: Calendar) -> UsageTrendHeatmap {
        let start = rows.first?.date ?? today
        let end = rows.last?.date ?? today
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
        let maximum = rows.compactMap(\.tokens).max()
        let weekdayOrder = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        var columns = [UsageTrendHeatmapColumn]()
        var ticks = [UsageTrendMonthTick]()
        var previousMonth: String?
        var week = weekStart(for: start, calendar: calendar)
        while week <= end {
            let index = columns.count
            var cells = [UsageTrendHeatmapCell]()
            for row in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: row, to: week) else { continue }
                let day = key(for: date, civil: civil)
                let included = date >= start && date <= end
                let tokens = included ? values[day]?.tokens : nil
                let intensity: Int?
                if let tokens {
                    if tokens == 0 { intensity = 0 }
                    else {
                        let ratio = Double(tokens) / Double(maximum ?? tokens)
                        intensity = ratio <= 0.25 ? 1 : ratio <= 0.5 ? 2 : ratio <= 0.75 ? 3 : 4
                    }
                } else { intensity = nil }
                cells.append(UsageTrendHeatmapCell(day: day, date: date,
                                                  weekday: calendar.component(.weekday, from: date),
                                                  tokens: tokens, insideRange: included, isFuture: date > today,
                                                  intensity: intensity))
                if included {
                    let parts = civil.dateComponents([.year, .month], from: date)
                    let monthID = "\(parts.year ?? 0)-\(parts.month ?? 0)"
                    if previousMonth != monthID {
                        ticks.append(UsageTrendMonthTick(column: index, date: date,
                                                       year: parts.year ?? 0, month: parts.month ?? 0))
                        previousMonth = monthID
                    }
                }
            }
            columns.append(UsageTrendHeatmapColumn(day: key(for: week, civil: civil), index: index,
                                                   startDate: week, endDate: cells.last?.date ?? week, cells: cells))
            guard let next = calendar.date(byAdding: .day, value: 7, to: week), next > week else { break }
            week = next
        }
        return UsageTrendHeatmap(startDate: start, endDate: end, weekdayOrder: weekdayOrder,
                                 columns: columns, monthTicks: ticks,
                                 coverage: UsageTrendCoverage(expectedDays: rows.count, knownDays: rows.filter { $0.tokens != nil }.count),
                                 maximumTokens: maximum)
    }
}
