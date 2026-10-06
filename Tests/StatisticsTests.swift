import Foundation

@main struct StatisticsTests {
    static func main() throws {
        let old = try UsageStatistics.decode(Data(#"{"profile":{"display_name":"Synthetic"},"stats":{"lifetime_tokens":4860000000,"peak_daily_tokens":320000000,"longest_running_turn_sec":22500,"current_streak_days":9,"longest_streak_days":24,"daily_usage_buckets":[{"start_date":"2026-09-30","tokens":100},{"start_date":"2026-09-28","tokens":0}]}}"#.utf8))
        precondition(old.lifetimeTokens == 4860000000 && old.peakDailyTokens == 320000000)
        precondition(old.currentStreakDays == 9 && old.longestStreakDays == 24 && old.longestRunningTurnSec == 22500)
        precondition(old.daily?.map(\.day) == ["2026-09-28","2026-09-30"])
        precondition(old.daily?.first?.tokens == 0,"Returned zero is real data")
        let modern = try UsageStatistics.decode(Data(#"{"summary":{"lifetimeTokens":100,"peakDailyTokens":30,"longestRunningTurnSec":600,"currentStreakDays":2,"longestStreakDays":4},"dailyUsageBuckets":[{"startDate":"2026-09-30","tokens":30}]}"#.utf8))
        precondition(modern.lifetimeTokens == 100 && modern.daily?.first?.tokens == 30)
        let nested = try UsageStatistics.decode(Data(#"{"stats":{"current_streak_days":2,"longest_streak_days":5,"agentic":{"lifetime_tokens":200,"peak_daily_tokens":20}},"activity_graph":{"daily_usage_buckets":[{"start_date":"2026-09-30","tokens":20}]}}"#.utf8))
        precondition(nested.lifetimeTokens == 200 && nested.currentStreakDays == 2 && nested.daily?.count == 1)
        let absent = try UsageStatistics.decode(Data(#"{"stats":null}"#.utf8))
        precondition(absent.lifetimeTokens == nil && absent.daily == nil)
        let empty = try UsageStatistics.decode(Data(#"{"stats":{"daily_usage_buckets":[]}}"#.utf8))
        precondition(empty.daily == [])
        let invalid = try UsageStatistics.decode(Data(#"{"stats":{"lifetime_tokens":true,"peak_daily_tokens":-1,"current_streak_days":0.5,"longest_streak_days":1e50,"longest_running_turn_sec":null,"daily_usage_buckets":[{"start_date":"2026-02-30","tokens":10},{"start_date":"2026-09-30","tokens":-1},{"start_date":"not-a-date","tokens":5}]}}"#.utf8))
        precondition(invalid.lifetimeTokens == nil && invalid.peakDailyTokens == nil && invalid.currentStreakDays == nil && invalid.longestStreakDays == nil && invalid.daily == nil)
        let duplicates = try UsageStatistics.decode(Data(#"{"stats":{"daily_usage_buckets":[{"start_date":"2026-09-30","tokens":1},{"start_date":"2026-09-30","tokens":2},{"start_date":"2026-09-28","tokens":3}]}}"#.utf8))
        precondition(duplicates.daily?.map(\.day) == ["2026-09-28"])
        for body in ["{}","[]","invalid-json"] {
            do { _ = try UsageStatistics.decode(Data(body.utf8));fatalError("Malformed stats accepted") }
            catch UsageFailure.malformed {}
        }
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
        let now = calendar.date(from:DateComponents(year:2026,month:9,day:30,hour:12))!
        precondition(old.history(days:2,now:now).map(\.day) == ["2026-09-29","2026-09-30"])
        precondition(old.history(days:3,now:now).map(\.tokens) == [0,0,100],"Missing calendar days must plot at zero")
        let month = old.history(days:30,now:now)
        precondition(month.count == 30 && month.first?.day == "2026-09-01" && month.last?.day == "2026-09-30")
        let noToday = UsageStatistics(lifetimeTokens:nil,peakDailyTokens:nil,longestRunningTurnSec:nil,longestStreakDays:nil,currentStreakDays:nil,daily:[DailyTokenUsage(day:"2026-09-28",tokens:3)])
        precondition(noToday.history(days:30,now:now).last?.day == "2026-09-29" && noToday.history(days:30,now:now).count == 30,
                     "Absent current day must be omitted; retain a full range ending yesterday")
        let todayZero = UsageStatistics(lifetimeTokens:nil,peakDailyTokens:nil,longestRunningTurnSec:nil,longestStreakDays:nil,currentStreakDays:nil,
            daily:[DailyTokenUsage(day:"2026-09-30",tokens:0)])
        precondition(todayZero.history(days:7,now:now).last?.day == "2026-09-30" && todayZero.history(days:7,now:now).last?.tokens == 0,
                     "An explicitly returned zero for today remains real data")
        precondition(duplicates.history(days:7,now:now).last?.day == "2026-09-29","An ambiguous current-day bucket must not be fabricated")
        for days in [7,14,30] {
            let history = noToday.history(days:days,now:now)
            precondition(history.count == days && history.last?.day == "2026-09-29")
        }
        precondition(empty.history(days:30,now:now).count == 30 && empty.history(days:30,now:now).allSatisfy { $0.tokens == 0 })
        precondition(absent.history(days:30,now:now).isEmpty && invalid.history(days:30,now:now).isEmpty,"Unavailable or malformed history must stay unavailable")
        let newYear = calendar.date(from:DateComponents(year:2027,month:1,day:2,hour:12))!
        let boundary = empty.history(days:7,now:newYear)
        precondition(boundary.first?.day == "2026-12-26" && boundary.last?.day == "2027-01-01")
        let time = Date(timeIntervalSince1970:1000)
        precondition(!UsageStatistics.shouldRefresh(now:time,lastAttempt:time.addingTimeInterval(-299),failures:0))
        precondition(UsageStatistics.shouldRefresh(now:time,lastAttempt:time.addingTimeInterval(-300),failures:0))
        precondition(!UsageStatistics.shouldRefresh(now:time,lastAttempt:time.addingTimeInterval(-959),failures:4))
        precondition(UsageStatistics.shouldRefresh(now:time,lastAttempt:time,failures:4,force:true))
        precondition(StatisticsFormat.tokens(nil) == "—" && StatisticsFormat.duration(nil) == "—")
        precondition(StatisticsFormat.duration(22500) == "6h 15m")
        precondition(StatisticsFormat.duration(0) == "<1m" && StatisticsFormat.duration(65) == "1m")
        precondition(UsageStatistics.demo(now:now).history(days:14,now:now).count == 14)
        print("Statistics tests passed: legacy/current schemas, missing vs zero, dates, duplicates, invalid values, time ranges, refresh backoff, formatting")
    }
}
