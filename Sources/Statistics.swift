import Foundation
import CoreFoundation

struct DailyTokenUsage: Equatable, Identifiable {
    let day: String
    let tokens: Int64
    var id: String { day }
    var date: Date {
        let parts = day.split(separator:"-").compactMap { Int($0) }
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.date(from:DateComponents(year:parts[0],month:parts[1],day:parts[2]))!
    }
}

struct UsageStatistics: Equatable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let longestStreakDays: Int64?
    let currentStreakDays: Int64?
    // nil is unavailable; an empty array is an explicitly empty history.
    let daily: [DailyTokenUsage]?

    static func decode(_ data: Data) throws -> UsageStatistics {
        guard let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              root.keys.contains("stats") || root.keys.contains("summary") else { throw UsageFailure.malformed }
        let stats = root["stats"] as? [String:Any] ?? root["summary"] as? [String:Any] ?? [:]
        let agentic = stats["agentic"] as? [String:Any] ?? stats
        func integer(_ value: Any?) -> Int64? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite, d >= 0, d < 9_223_372_036_854_775_808, d.rounded(.towardZero) == d else { return nil }
            return Int64(n.stringValue) ?? Int64(d)
        }
        let graph = root["activity_graph"] as? [String:Any]
        let rawDaily = stats["daily_usage_buckets"] ?? graph?["daily_usage_buckets"] ?? root["dailyUsageBuckets"]
        var daily: [DailyTokenUsage]?
        if let rows = rawDaily as? [[String:Any]] {
            var seen = Set<String>()
            var duplicates = Set<String>()
            var parsed = [DailyTokenUsage]()
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier:.gregorian)
            formatter.locale = Locale(identifier:"en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT:0)
            formatter.dateFormat = "yyyy-MM-dd";formatter.isLenient = false
            for row in rows {
                guard let day = (row["start_date"] ?? row["startDate"]) as? String,
                      day.count == 10, let date = formatter.date(from:day), formatter.string(from:date) == day,
                      let tokens = integer(row["tokens"]) else { continue }
                if !seen.insert(day).inserted { duplicates.insert(day) }
                parsed.append(DailyTokenUsage(day:day,tokens:tokens))
            }
            // Ambiguous duplicate dates are omitted, never double-counted.
            daily = parsed.filter { !duplicates.contains($0.day) }.sorted { $0.day < $1.day }
            if !rows.isEmpty && daily?.isEmpty == true { daily = nil }
        }
        return UsageStatistics(
            lifetimeTokens:integer(agentic["lifetime_tokens"] ?? agentic["lifetimeTokens"]),
            peakDailyTokens:integer(agentic["peak_daily_tokens"] ?? agentic["peakDailyTokens"]),
            longestRunningTurnSec:integer(agentic["longest_running_turn_sec"] ?? agentic["longestRunningTurnSec"]),
            longestStreakDays:integer(stats["longest_streak_days"] ?? stats["longestStreakDays"]),
            currentStreakDays:integer(stats["current_streak_days"] ?? stats["currentStreakDays"]),daily:daily)
    }

    func history(days: Int, now: Date = Date()) -> [DailyTokenUsage] {
        guard let daily else { return [] }
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
        let end = calendar.startOfDay(for:now)
        let count = max(1,min(30,days))
        let formatter = DateFormatter();formatter.calendar = calendar
        formatter.locale = Locale(identifier:"en_US_POSIX");formatter.timeZone = calendar.timeZone;formatter.dateFormat = "yyyy-MM-dd"
        let values = daily.reduce(into:[String:Int64]()) { $0[$1.day] = $1.tokens }
        return (0..<count).map { index in
            let date = calendar.date(byAdding:.day,value:index-count+1,to:end)!
            let day = formatter.string(from:date)
            return DailyTokenUsage(day:day,tokens:values[day] ?? 0)
        }
    }
    static func shouldRefresh(now: Date, lastAttempt: Date, failures: Int, force: Bool = false) -> Bool {
        force || now.timeIntervalSince(lastAttempt) >= max(300,RefreshPolicy.interval(failures:failures))
    }
    static func demo(now: Date = Date()) -> UsageStatistics {
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
        let formatter = DateFormatter();formatter.calendar = calendar
        formatter.locale = Locale(identifier:"en_US_POSIX");formatter.timeZone = calendar.timeZone;formatter.dateFormat = "yyyy-MM-dd"
        let values: [Int64] = [12,23,37,68,90,112,87,130,106,174,150,246,320,210]
        let daily = values.enumerated().map { i,value in
            DailyTokenUsage(day:formatter.string(from:calendar.date(byAdding:.day,value:i-13,to:now)!),tokens:value*1_000_000)
        }
        return UsageStatistics(lifetimeTokens:4_860_000_000,peakDailyTokens:320_000_000,
            longestRunningTurnSec:22_500,longestStreakDays:24,currentStreakDays:9,daily:daily)
    }
}

enum StatisticsFormat {
    static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let n = Double(value)
        let units: [(Double,String)] = AppLanguage.chinese
            ? [(100_000_000,"亿"),(10_000,"万")]
            : [(1_000_000_000,"B"),(1_000_000,"M"),(1_000,"K")]
        let formatter = NumberFormatter();formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .decimal;formatter.maximumFractionDigits = 1
        for (scale,suffix) in units where n >= scale {
            return (formatter.string(from:NSNumber(value:n/scale)) ?? "—") + suffix
        }
        formatter.maximumFractionDigits = 0
        return formatter.string(from:NSNumber(value:value)) ?? "—"
    }
    static func duration(_ seconds: Int64?) -> String {
        guard let seconds else { return "—" }
        let minutes = seconds / 60
        if seconds < 60 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    static func days(_ days: Int64?) -> String {
        days.map { L("\($0)天", "\($0)d") } ?? "—"
    }
}
