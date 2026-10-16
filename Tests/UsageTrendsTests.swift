import Foundation

@main struct UsageTrendsTests {
    static func main() {
        let calendar = makeCalendar(zone: "UTC", firstWeekday: 2)
        let now = date(2026, 10, 11, calendar: calendar)
        let source = statistics([
            DailyTokenUsage(day: "2026-10-05", tokens: 0),
            DailyTokenUsage(day: "2026-10-07", tokens: 100),
            DailyTokenUsage(day: "2026-10-08", tokens: 50)
        ], lifetime: 9_999)
        let trend = UsageTrends(statistics: source, now: now, calendar: calendar)
        precondition(trend.dailyRows.count == 30 && trend.dailyRows.first?.day == "2026-09-12")
        precondition(trend.dailyRows.last?.day == "2026-10-11" && trend.dailyRows.last?.tokens == nil,
                     "Unreported today is displayed as missing, never shifted away or filled with zero")
        precondition(day("2026-10-05", in: trend).tokens == 0 && day("2026-10-06", in: trend).tokens == nil)
        precondition(trend.knownTotal == 150 && !trend.totalOverflowed && trend.knownTotal != source.lifetimeTokens)
        precondition(trend.coverage.knownDays == 3 && trend.coverage.missingDays == 27 && trend.coverage.isPartial)
        precondition(trend.historyState == .available)
        precondition(point("2026-10-05", in: trend.cumulativeRows).tokens == 0)
        precondition(point("2026-10-06", in: trend.cumulativeRows).tokens == nil,
                     "Unreported dates retain no invented cumulative point")
        let running = point("2026-10-08", in: trend.cumulativeRows)
        precondition(running.tokens == 150 && running.knownDays == 3 && running.isPartial)
        precondition(trend.points(for: .daily).map(\.tokens) == trend.dailyRows.map(\.tokens))
        precondition(trend.points(for: .weekly) == trend.weeklyRows && trend.points(for: .cumulative) == trend.cumulativeRows)
        precondition(Set(trend.points(for: .daily).map(\.id)).count == 30)
        let shortMap=trend.heatmap(for:.days30),ninetyMap=trend.heatmap(for:.days90)
        precondition(shortMap.coverage.expectedDays == 30 && ninetyMap.coverage.expectedDays == 90)
        precondition(shortMap.columns.flatMap(\.cells).filter(\.insideRange).map(\.day) == trend.dailyRows.map(\.day))
        precondition(shortMap.columns.allSatisfy { $0.cells.count == 7 } && shortMap.weekdayOrder == trend.heatmap.weekdayOrder)
        let extended=trend.selectingRange(.days90)
        precondition(extended == UsageTrends(statistics:source,range:.days90,now:now,calendar:calendar),"Range reuse matches a fresh calculation")
        precondition(extended.heatmap == trend.heatmap && extended.selectingRange(.days30) == trend,"Curve range never narrows the independent annual grid")
        precondition(trend.heatmap(for:.year) == trend.heatmap)
        let segments=trend.chartSegments(for:.daily)
        precondition(segments.count == 2 && segments[0].points.map(\.day) == ["2026-10-05"])
        precondition(segments[0].points[0].tokens == 0 && segments[1].points.map(\.day) == ["2026-10-07","2026-10-08"],
                     "Reported zero stays on the curve and missing dates split line/area series")
        let cumulativeSegments=trend.chartSegments(for:.cumulative)
        precondition(cumulativeSegments.count == 1 && cumulativeSegments[0].points.map(\.day) == ["2026-10-05","2026-10-07","2026-10-08"],
                     "Cumulative totals connect known dates across gaps without inserting unknown points")
        precondition(cumulativeSegments[0].points.compactMap(\.tokens) == [0,100,150],
                     "Cumulative links preserve reported zero and add only known usage")
        for grouping in UsageTrendGrouping.allCases {
            precondition(trend.chartSegments(for:grouping).flatMap(\.points) == trend.points(for:grouping).filter { $0.tokens != nil })
        }
        let currentWeek = trend.weeklyRows.last!
        precondition(currentWeek.isCurrentWeek && currentWeek.startDate == date(2026, 10, 5, hour: 0, calendar: calendar))
        precondition(currentWeek.endDate == calendar.startOfDay(for: now) && currentWeek.expectedDays == 7)
        precondition(currentWeek.tokens == 150 && currentWeek.knownDays == 3 && currentWeek.isPartial && !currentWeek.isPartialPeriod)

        let unavailable = UsageTrends(statistics: nil, now: now, calendar: calendar)
        let missing = UsageTrends(statistics: statistics(nil), now: now, calendar: calendar)
        let empty = UsageTrends(statistics: statistics([]), now: now, calendar: calendar)
        let outside = UsageTrends(statistics: statistics([DailyTokenUsage(day: "2020-01-01", tokens: 5)]), now: now, calendar: calendar)
        precondition(unavailable.historyState == .unavailable && missing.historyState == .unavailable)
        precondition(empty.historyState == .empty && outside.historyState == .outsideRange)
        for model in [unavailable, missing, empty, outside] {
            precondition(model.knownTotal == nil && model.coverage.knownDays == 0 && !model.totalOverflowed)
            precondition(model.dailyRows.allSatisfy { $0.tokens == nil })
            precondition(model.heatmap.columns.flatMap(\.cells).allSatisfy { $0.tokens == nil && $0.intensity == nil })
        }
        let older = UsageTrends(statistics: statistics([DailyTokenUsage(day: "2026-08-01", tokens: 5)]), now: now, calendar: calendar)
        precondition(older.historyState == .outsideRange && older.heatmap.coverage.knownDays == 1,
                     "Annual calendar can contain data outside the selected short range")

        let invalid = UsageTrends(statistics: statistics([
            DailyTokenUsage(day: "2026-10-07", tokens: 2), DailyTokenUsage(day: "2026-10-07", tokens: 2),
            DailyTokenUsage(day: "2026-10-08", tokens: 3), DailyTokenUsage(day: "2026-10-08", tokens: 4),
            DailyTokenUsage(day: "2026-09-31", tokens: 10), DailyTokenUsage(day: "2026-10-01x", tokens: 10),
            DailyTokenUsage(day: "2026-10-10", tokens: -1), DailyTokenUsage(day: "2026-10-12", tokens: 10),
            DailyTokenUsage(day: "not-a-date", tokens: 10), DailyTokenUsage(day: "0000-01-01", tokens: 10),
            DailyTokenUsage(day: "2026-10-09", tokens: 0)
        ]), now: now, calendar: calendar)
        precondition(day("2026-10-07", in: invalid).tokens == nil && day("2026-10-08", in: invalid).tokens == nil)
        precondition(invalid.coverage.knownDays == 1 && invalid.knownTotal == 0)
        precondition(invalid.heatmap.maximumTokens == 0)
        precondition(invalid.heatmap.columns.flatMap(\.cells).filter { $0.tokens == 0 }.allSatisfy { $0.intensity == 0 })

        let fullBuckets = rows(ending: now, count: 30, calendar: calendar) { Int64($0) }
        let complete = UsageTrends(statistics: statistics(fullBuckets), now: now, calendar: calendar)
        precondition(complete.knownTotal == 435 && !complete.coverage.isPartial && complete.coverage.knownDays == 30)
        precondition(complete.cumulativeRows.last?.tokens == 435 && complete.cumulativeRows.allSatisfy { !$0.isPartial })
        precondition(complete.weeklyRows.compactMap(\.tokens).reduce(0, +) == 435)

        checkWeeksAcrossNewYear()
        checkAnnualAndLeapBoundaries()
        checkDSTAndLocale()
        checkOverflow()
        checkSharedDataset(trend)
        print("Usage trends tests passed: missing/zero, unavailable/empty/coverage, bounded invalid/duplicate input, daily/weekly/cumulative consistency, calendar/week/year/DST boundaries, heatmap mapping, overflow")
    }

    private static func statistics(_ daily: [DailyTokenUsage]?, lifetime: Int64? = nil) -> UsageStatistics {
        UsageStatistics(lifetimeTokens: lifetime, peakDailyTokens: nil, longestRunningTurnSec: nil,
                        longestStreakDays: nil, currentStreakDays: nil, daily: daily)
    }

    private static func makeCalendar(zone: String, firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func key(_ date: Date, calendar: Calendar) -> String {
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        let parts = civil.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func rows(ending now: Date, count: Int, calendar: Calendar,
                             values: (Int) -> Int64) -> [DailyTokenUsage] {
        let end = calendar.startOfDay(for: now)
        return (0..<count).map { index in
            let date = calendar.date(byAdding: .day, value: index - count + 1, to: end)!
            return DailyTokenUsage(day: key(date, calendar: calendar), tokens: values(index))
        }
    }

    private static func day(_ key: String, in trend: UsageTrends) -> UsageTrendDay {
        trend.dailyRows.first { $0.day == key }!
    }

    private static func point(_ key: String, in points: [UsageTrendPoint]) -> UsageTrendPoint {
        points.first { $0.day == key }!
    }

    private static func checkWeeksAcrossNewYear() {
        let monday = makeCalendar(zone: "UTC", firstWeekday: 2)
        let now = date(2027, 1, 1, calendar: monday)
        let trend = UsageTrends(statistics: statistics(rows(ending: now, count: 30, calendar: monday) { _ in 1 }),
                                now: now, calendar: monday)
        let week = trend.weeklyRows.last!
        precondition(week.day == "2027-01-01" && key(week.periodStartDate, calendar: monday) == "2026-12-28")
        precondition(key(week.periodEndDate, calendar: monday) == "2027-01-03")
        precondition(week.tokens == 5 && week.expectedDays == 5 && week.knownDays == 5)
        precondition(week.isCurrentWeek && week.isPartialPeriod && !week.isPartial,
                     "An in-progress calendar week and missing coverage are different conditions")
        precondition(trend.weeklyRows.first!.isPartialPeriod)
        let sunday = makeCalendar(zone: "UTC", firstWeekday: 1)
        let sundayTrend = UsageTrends(statistics: statistics([]), now: now, calendar: sunday)
        precondition(key(sundayTrend.weeklyRows.last!.periodStartDate, calendar: sunday) == "2026-12-27")
        precondition(sundayTrend.weeklyRows.last!.expectedDays == 6)
        precondition(trend.heatmap.weekdayOrder == [2, 3, 4, 5, 6, 7, 1])
        precondition(sundayTrend.heatmap.weekdayOrder == [1, 2, 3, 4, 5, 6, 7])
        precondition(trend.weeklyRows.map(\.date) == trend.weeklyRows.map(\.date).sorted())
        precondition(Set(trend.weeklyRows.map(\.id)).count == trend.weeklyRows.count)
    }

    private static func checkAnnualAndLeapBoundaries() {
        let calendar = makeCalendar(zone: "UTC", firstWeekday: 2)
        for (year, month, day, expectedStart, expectedCount) in [
            (2026, 10, 11, "2025-10-12", 365),
            (2024, 2, 29, "2023-03-01", 366),
            (2025, 2, 28, "2024-02-29", 366),
            (2027, 1, 1, "2026-01-02", 365)
        ] {
            let now = date(year, month, day, calendar: calendar)
            let trend = UsageTrends(statistics: statistics([]), range: .year, now: now, calendar: calendar)
            precondition(trend.dailyRows.first?.day == expectedStart && trend.dailyRows.count == expectedCount)
            precondition(trend.heatmap.coverage.expectedDays == expectedCount)
            precondition((53...54).contains(trend.heatmap.columns.count))
            let cells = trend.heatmap.columns.flatMap(\.cells)
            precondition(cells.filter(\.insideRange).map(\.day) == trend.dailyRows.map(\.day))
            precondition(Set(cells.map(\.id)).count == cells.count)
            for column in trend.heatmap.columns {
                precondition(column.cells.count == 7 && column.cells.map(\.weekday) == trend.heatmap.weekdayOrder)
                precondition(column.index >= 0 && column.index < trend.heatmap.columns.count)
                precondition(column.cells.map(\.date) == column.cells.map(\.date).sorted())
            }
            for cell in cells where !cell.insideRange {
                precondition(cell.tokens == nil && cell.intensity == nil && cell.isFuture == (cell.date > trend.rangeEndDate))
            }
            for tick in trend.heatmap.monthTicks {
                let matching = trend.heatmap.columns[tick.column].cells.first { $0.date == tick.date }!
                precondition(matching.insideRange)
                let parts = calendar.dateComponents([.year, .month, .day], from: tick.date)
                precondition(parts.year == tick.year && parts.month == tick.month)
                precondition(tick.date == trend.heatmap.startDate || parts.day == 1)
            }
            checkSharedDataset(trend)
        }
        let now = date(2026, 10, 11, calendar: calendar)
        let ninety = UsageTrends(statistics: statistics([]), range: .days90, now: now, calendar: calendar)
        precondition(ninety.dailyRows.count == 90 && ninety.dailyRows.first?.day == "2026-07-14")
    }

    private static func checkDSTAndLocale() {
        for zone in ["America/Los_Angeles", "Europe/Berlin", "Asia/Shanghai"] {
            var calendar = makeCalendar(zone: zone, firstWeekday: 2)
            calendar.locale = Locale(identifier: "ar_SA")
            let now = date(2026, 11, 8, calendar: calendar)
            let source = statistics(rows(ending: now, count: 90, calendar: calendar) { _ in 2 })
            let trend = UsageTrends(statistics: source, range: .days90, now: now, calendar: calendar)
            precondition(trend.dailyRows.count == 90 && trend.coverage.knownDays == 90 && trend.knownTotal == 180)
            precondition(Set(trend.dailyRows.map(\.day)).count == 90)
            precondition(trend.dailyRows.first?.day == "2026-08-11" && trend.dailyRows.last?.day == "2026-11-08")
            for row in trend.dailyRows { precondition(key(row.date, calendar: calendar) == row.day) }
            if zone == "America/Los_Angeles" {
                let nov1 = day("2026-11-01", in: trend).date
                let nov2 = day("2026-11-02", in: trend).date
                precondition(nov2.timeIntervalSince(nov1) == 25 * 3_600,
                             "Calendar-day arithmetic must survive the fall DST transition")
                let springNow = date(2026, 3, 15, calendar: calendar)
                let spring = UsageTrends(statistics: statistics([]), now: springNow, calendar: calendar)
                precondition(day("2026-03-09", in: spring).date.timeIntervalSince(day("2026-03-08", in: spring).date) == 23 * 3_600)
            }
            checkSharedDataset(trend)
        }
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = TimeZone(secondsFromGMT: 0)!
        let isoTrend = UsageTrends(statistics: statistics([]), now: date(2027, 1, 1, calendar: iso), calendar: iso)
        precondition(isoTrend.heatmap.weekdayOrder == [2, 3, 4, 5, 6, 7, 1])
        precondition(key(isoTrend.weeklyRows.last!.periodStartDate, calendar: iso) == "2026-12-28")
    }

    private static func checkOverflow() {
        let calendar = makeCalendar(zone: "UTC", firstWeekday: 2)
        let now = date(2026, 10, 11, calendar: calendar)
        let source = statistics([
            DailyTokenUsage(day: "2026-10-05", tokens: Int64.max),
            DailyTokenUsage(day: "2026-10-06", tokens: 1),
            DailyTokenUsage(day: "2026-10-08", tokens: 0)
        ])
        let trend = UsageTrends(statistics: source, now: now, calendar: calendar)
        precondition(day("2026-10-05", in: trend).tokens == Int64.max)
        precondition(trend.knownTotal == nil && trend.totalOverflowed)
        precondition(trend.weeklyRows.last?.tokens == nil && trend.weeklyRows.last?.overflowed == true)
        precondition(point("2026-10-05", in: trend.cumulativeRows).tokens == Int64.max)
        for day in ["2026-10-06", "2026-10-07", "2026-10-08", "2026-10-11"] {
            let row = point(day, in: trend.cumulativeRows)
            precondition(row.tokens == nil && row.overflowed)
        }
        precondition(trend.heatmap.maximumTokens == Int64.max)
        precondition(trend.chartSegments(for:.cumulative).flatMap(\.points).count == 1,"Overflow breaks cumulative line and area data")
        let fullLimit = UsageTrends(statistics: statistics([
            DailyTokenUsage(day: "2026-10-10", tokens: Int64.max), DailyTokenUsage(day: "2026-10-11", tokens: 0)
        ]), now: now, calendar: calendar)
        precondition(fullLimit.knownTotal == Int64.max && !fullLimit.totalOverflowed)
        precondition(fullLimit.cumulativeRows.last?.tokens == Int64.max)
    }

    private static func checkSharedDataset(_ trend: UsageTrends) {
        let cells = trend.heatmap.columns.flatMap(\.cells).filter(\.insideRange)
        let calendarValues = Dictionary(uniqueKeysWithValues: cells.map { ($0.day, $0) })
        for row in trend.dailyRows {
            let cell = calendarValues[row.day]!
            precondition(cell.tokens == row.tokens && cell.date == row.date)
            precondition(cell.intensity == nil || row.tokens != nil)
        }
        precondition(trend.points(for: .daily).map(\.day) == trend.dailyRows.map(\.day))
        precondition(trend.cumulativeRows.map(\.day) == trend.dailyRows.map(\.day))
        precondition(trend.weeklyRows.reduce(0) { $0 + $1.expectedDays } == trend.dailyRows.count)
        precondition(trend.weeklyRows.reduce(0) { $0 + $1.knownDays } == trend.coverage.knownDays)
        for row in trend.weeklyRows {
            let days = trend.dailyRows.filter { $0.date >= row.startDate && $0.date <= row.endDate }
            precondition(days.count == row.expectedDays && days.filter { $0.tokens != nil }.count == row.knownDays)
        }
    }
}
