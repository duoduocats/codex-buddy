import AppKit
import Combine

struct UsageForecastHistoryRow: Identifiable, Equatable {
    let id: String
    let date: Date?
    let title: String
    let detail: String
    let sourceURL: URL?
}

// Forecast navigation and scenarios are local to this page. Choosing a window
// or an extra reset never changes the menu-bar quota selection or real quota.
@MainActor final class UsageForecastPresentation: ObservableObject {
    @Published private(set) var snapshot: UsageForecastSnapshot
    @Published private(set) var selectedWindowID: String?
    @Published private(set) var now: Date
    @Published private(set) var refreshing: Bool
    @Published private(set) var quotaError: Bool
    // Kept as a compatibility property; the single simulation switch is the
    // only scenario gate. There is no separate normal/scenario page.
    var extraResetMode = false
    @Published private(set) var comparison: UsageForecastComparison?
    @Published private(set) var tiboSummary = ""
    @Published private(set) var evaluationSummary = ""
    @Published private(set) var tiboHistoryRows: [UsageForecastHistoryRow] = []
    @Published private(set) var evaluationRows: [UsageForecastHistoryRow] = []
    private var tiboEstimate: Date?
    @Published var extraResetEnabled = false {
        didSet {
            guard oldValue != extraResetEnabled else { return }
            if extraResetEnabled && extraResetDate <= now { extraResetDate = suggestedExtraDate }
            rebuild()
        }
    }
    @Published var extraResetDate: Date { didSet { if oldValue != extraResetDate { rebuild() } } }
    let model: AppModel
    let sample: Bool
    private var usage: UsageResponse?
    private var observations: [UsageForecastObservation]
    private var updated: Date?
    private var identity: String?
    private var explicitWindowSelection = false
    private var clockKey: String
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model=model;sample=model.isDemonstrating;now=model.now;refreshing=model.refreshing;quotaError=model.error != nil
        usage=model.usage;observations=model.forecastObservations;updated=model.forecastUpdated;identity=model.forecastIdentity
        let initial=UsageForecastSnapshot(usage:model.usage,observations:model.forecastObservations,
            updated:model.forecastUpdated,now:model.now)
        snapshot=initial;selectedWindowID=Self.preferredWindow(initial)?.id
        let reset=Self.preferredWindow(initial)?.resetDate
        extraResetDate=reset.map { model.now.addingTimeInterval(min(28*86400,max(60,$0.timeIntervalSince(model.now)/2))) }
            ?? model.now.addingTimeInterval(3*3600)
        if sample,let selected=model.demoForecastExtraDate { extraResetDate=selected;extraResetEnabled=true }
        clockKey=Self.key(model.now)
        rebuildComparison();rebuildResearch()
        model.$usage.combineLatest(model.$forecastObservations,model.$forecastUpdated)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
            .sink { [weak self] usage,observations,updated in
                guard let self else { return }
                self.usage=usage;self.observations=observations;self.updated=updated
                self.now=self.model.now;self.clockKey=Self.key(self.now);self.rebuild()
            }.store(in:&subscriptions)
        model.$forecastIdentity.removeDuplicates().sink { [weak self] value in
            guard let self,self.identity != value else { return }
            self.identity=value;self.explicitWindowSelection=false;self.extraResetEnabled=false;self.rebuild()
        }.store(in:&subscriptions)
        model.$error.removeDuplicates().sink { [weak self] value in
            guard let self else { return };self.quotaError=value != nil;self.rebuildComparison()
        }.store(in:&subscriptions)
        model.$forecastEvaluations.removeDuplicates().sink { [weak self] _ in self?.rebuildResearch() }.store(in:&subscriptions)
        model.reminders.objectWillChange.sink { [weak self] _ in
            // Published values are delivered before mutation. Project the
            // retained feed after that mutation; never issue a new fetch.
            DispatchQueue.main.async { [weak self] in self?.rebuildResearch() }
        }.store(in:&subscriptions)
        model.$refreshing.removeDuplicates().sink { [weak self] in self?.refreshing=$0 }.store(in:&subscriptions)
        model.$now.sink { [weak self] value in
            guard let self else { return }
            let key=Self.key(value)
            guard key != self.clockKey else { return }
            self.clockKey=key;self.now=value;self.rebuild()
        }.store(in:&subscriptions)
    }
    var window: UsageForecastWindow? { snapshot.windows.first(where: { $0.id == selectedWindowID }) ?? Self.preferredWindow(snapshot) }
    var simulated: Bool { extraResetEnabled }
    var scenarioWindow: UsageForecastScenarioWindow? {
        guard simulated,let window else { return nil }
        return snapshot.scenario?.windows.first(where: { $0.windowID == window.windowID })
    }
    var relevantScenario: Bool { scenarioWindow?.relevant == true }
    var effectiveResetDate: Date? {
        relevantScenario ? scenarioWindow?.effectiveResetDate : window?.resetDate
    }
    var waitingForUpdate: Bool { quotaError || window?.state == .stale }
    var currentPercentPerHour: Double? { waitingForUpdate ? nil : window?.observedPercentPerHour }
    var safePercentPerHour: Double? {
        guard !waitingForUpdate else { return nil }
        return relevantScenario ? scenarioWindow?.safePercentPerHour : window?.safePercentPerHour
    }
    var exhaustionDate: Date? {
        guard !waitingForUpdate else { return nil }
        return relevantScenario ? scenarioWindow?.exhaustionDate : window?.exhaustionDate
    }
    var availabilityDate: Date? {
        guard !waitingForUpdate,window?.state == .ready,let reset=effectiveResetDate,reset > now else { return nil }
        return exhaustionDate.map { min($0,reset) } ?? reset
    }
    var exhaustsBeforeReset: Bool {
        guard let exhaustion=exhaustionDate,let reset=effectiveResetDate else { return false }
        return exhaustion < reset
    }
    var slowdownPercent: Double? {
        guard let current=currentPercentPerHour,current > 0,current.isFinite,
              let safe=safePercentPerHour,safe >= 0,safe.isFinite else { return nil }
        return max(0,min(100,(1-safe/current)*100))
    }
    var remainingTitle: String {
        guard let window else { return L("剩余额度", "Remaining") }
        let bucket=usage?.buckets.first(where: { $0.0 == window.windowID.bucketID })?.1
        let quota=window.windowID.role == .primary ? bucket?.primary : bucket?.secondary
        if quota?.windowDurationMins == 10080 { return L("本周剩余", "Weekly remaining") }
        return L("剩余额度", "Remaining")
    }
    var headline: String {
        if waitingForUpdate { return L("等待更新", "Awaiting update") }
        switch window?.state {
        case .waiting: return L("等待重置", "Awaiting reset")
        case .exhausted: return L("额度已用尽", "Quota exhausted")
        case .quiet: return L("变化较小", "Small changes")
        case .unavailable: return window?.resetDate == nil ? L("观察中", "Observing") : L("等待更新", "Awaiting update")
        case nil: return L("等待用量", "Awaiting usage")
        default: return L("观察中", "Observing")
        }
    }
    var status: String {
        if waitingForUpdate { return L("等待最新用量。", "Waiting for fresh usage.") }
        switch window?.state {
        case .ready:
            if exhaustsBeforeReset { return relevantScenario ? L("早于模拟重置。", "Before the simulated reset.") : L("早于下次重置。", "Before the next reset.") }
            return relevantScenario ? L("到模拟重置时再评估。", "Reassess at the simulated reset.") : L("预计可覆盖到重置。", "Estimated to last until reset.")
        case .exhausted: return L("等待下次重置。", "Waiting for the next reset.")
        case .quiet: return L("继续观察节奏。", "Keep watching the pace.")
        case .waiting: return L("等待额度更新。", "Waiting for quota to update.")
        case .unavailable: return window?.resetDate == nil ? L("等待重置时间。", "Waiting for reset timing.") : L("等待最新用量。", "Waiting for fresh usage.")
        case nil: return L("等待用量。", "Waiting for usage.")
        default: return L("等待用量变化。", "Watching usage changes.")
        }
    }
    var suggestion: String {
        if waitingForUpdate { return L("更新用量后再估计。", "Estimate again after usage updates.") }
        if window?.state == .exhausted { return L("暂无可用额度，等待重置。", "No quota remains. Waiting for reset.") }
        if simulated {
            return relevantScenario ? L("模拟场景，到选定时间再评估。", "In this scenario, reassess at the selected time.") : L("当前仍按常规重置估计。", "The estimate still uses the regular reset.")
        }
        guard window?.state == .ready else { return L("参考建议节奏使用。", "Use the suggested pace as a guide.") }
        return exhaustsBeforeReset ? L("适当放缓，预计可用到下次重置。", "Slow down slightly to help last until reset.") : L("按当前节奏，预计可用到下次重置。", "At the current pace, usage is estimated to last until reset.")
    }
    func windowLabel(_ forecast: UsageForecastWindow) -> String {
        guard let bucket=usage?.buckets.first(where: { $0.0 == forecast.windowID.bucketID })?.1 else { return L("额度", "Usage limit") }
        let quota=forecast.windowID.role == .primary ? bucket.primary : bucket.secondary
        let label=quota?.label ?? L("额度", "Usage limit")
        if let name=bucket.limitName,name != "codex",name != forecast.windowID.bucketID { return name+" · "+label }
        return label
    }
    func selectWindow(_ id: String) {
        guard snapshot.windows.contains(where: { $0.id == id }) else { return }
        explicitWindowSelection=true;selectedWindowID=id;rebuildComparison();rebuildResearch()
    }
    func refresh() { model.refresh(includeStatistics:false) }
    private var suggestedExtraDate: Date {
        guard let reset=window?.resetDate,reset > now else { return now.addingTimeInterval(3*3600) }
        return now.addingTimeInterval(min(28*86400,max(60,reset.timeIntervalSince(now)/2)))
    }
    private static func preferredWindow(_ snapshot: UsageForecastSnapshot) -> UsageForecastWindow? {
        snapshot.limitingWindow ?? snapshot.windows.filter { $0.hoursUntilReset != nil }.min { ($0.resetDate ?? .distantFuture) < ($1.resetDate ?? .distantFuture) } ?? snapshot.windows.first
    }
    private static func key(_ date: Date) -> String {
        "\(Int(date.timeIntervalSince1970/60))|\(TimeZone.autoupdatingCurrent.identifier)|\(Locale.autoupdatingCurrent.identifier)"
    }
    private func rebuild() {
        snapshot=UsageForecastSnapshot(usage:usage,observations:observations,updated:updated,now:now,
            extraResetDate:simulated ? extraResetDate : nil)
        if !explicitWindowSelection || !snapshot.windows.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowID=Self.preferredWindow(snapshot)?.id
        }
        rebuildComparison();rebuildResearch()
    }
    private func rebuildComparison() {
        let value=window.map { UsageForecastComparison(window:$0,now:now,scenarioEnabled:simulated,
            extraResetDate:simulated ? extraResetDate : nil,assumesFullReset:simulated,quotaError:quotaError,allowBudgetReference:true) }
        if comparison != value { comparison=value }
    }
    var baselineSafePercentPerHour: Double? { comparison?.normalSafePercentPerHour }
    var scenarioSafePercentPerHour: Double? { comparison?.preExtraSafePercentPerHour }
    var curveTitle:String {
        switch comparison?.projectionBasis {
        case .measured:return L("速度预测", "Pace forecast")
        case .provisional:return L("初步预测", "Early estimate")
        case .budget:return L("预算参考", "Budget reference")
        default:return L("常规", "Regular")
        }
    }
    var quotaHistoryRows:[UsageForecastHistoryRow] {
        guard let window else {return []}
        return UsageForecastObservation.segments(window.historicalObservations,at:now).enumerated().reversed().compactMap {ordinal,segment in
            guard let first=segment.observations.first,let last=segment.observations.last else {return nil}
            return .init(id:segment.id+"."+String(ordinal),date:first.observedAt,title:UsageForecastFormat.percent(100-first.usedPercent,digits:0)+" → "+UsageForecastFormat.percent(100-last.usedPercent,digits:0),detail:UsageForecastFormat.date(first.observedAt)+" – "+UsageForecastFormat.date(last.observedAt),sourceURL:nil)
        }
    }
    var baselineHeadline: String {
        if waitingForUpdate { return L("等待更新", "Awaiting update") }
        if comparison?.projectionBasis == .budget {return L("按重置时间分配", "Budget until reset")}
        if let date=comparison?.baselineExhaustionDate { return UsageForecastFormat.date(date) }
        if window?.state == .ready { return L("可用到重置", "Lasts until reset") }
        return headline
    }
    var baselineDetail: String {
        if waitingForUpdate { return L("更新用量后再估计", "Estimate after usage updates") }
        if comparison?.projectionBasis == .budget {return L("参考节奏，并非实际消耗预测", "Reference pace, not observed demand")}
        if comparison?.projectionBasis == .provisional {return L("依据已记录用量初步估计", "Early estimate from recorded usage")}
        if comparison?.baselineExhaustionDate != nil { return L("预计降至 0%", "Estimated to reach 0%") }
        if window?.state == .ready { return L("按当前使用节奏", "At the current pace") }
        if window?.state == .exhausted { return L("等待下次常规重置", "Waiting for the regular reset") }
        return L("继续观察用量变化", "Observing usage changes")
    }
    var extraHeadline: String {
        guard simulated else { return L("模拟额外重置", "Simulate an extra reset") }
        if waitingForUpdate || window?.resetDate == nil { return L("等待更新", "Awaiting update") }
        if window?.state == .waiting { return L("等待额度更新", "Waiting for quota") }
        guard comparison?.scenarioRelevant == true else { return L("当前周期不变", "Current cycle unchanged") }
        if comparison?.projectionBasis == .budget {return L("比较额外重置预算", "Compare extra-reset budget")}
        guard let seconds=comparison?.savedWaitingSeconds else { return L("继续观察", "Keep observing") }
        if seconds < 60 { return L("当前无需等待", "No waiting at this pace") }
        return L("可减少 \(UsageForecastFormat.number(seconds/3600)) 小时空档", "May avoid \(UsageForecastFormat.number(seconds/3600)) hours of waiting")
    }
    var extraDetail: String {
        guard simulated else { return L("开启后对比两条曲线", "Enable to compare both curves") }
        if waitingForUpdate || window?.resetDate == nil { return L("更新用量后再比较", "Compare after usage updates") }
        if window?.state == .waiting { return L("等待重置后的实际用量", "Waiting for usage after reset") }
        return comparison?.scenarioRelevant == true
            ? L("假设选定时刻恢复至 100%", "Assumes a full reset at the selected time")
            : L("请选择下次常规重置之前", "Choose a time before the regular reset")
    }
    var tiboEstimateAvailable: Bool { tiboEstimate != nil }
    func applyTiboEstimate() {
        guard let date=tiboEstimate,date > now,let reset=window?.resetDate,date < reset else { return }
        extraResetDate=date;extraResetEnabled=true
    }
    private func rebuildResearch() {
        let feed=model.reminders.recentMessages().filter { record in
            guard record.publishedAt <= now,let url=record.sourceURL,ResetAnnouncementDocument.validSourceURL(url),
                  ["x.com","twitter.com"].contains(url.host?.lowercased() ?? ""),url.path.hasPrefix("/thsottiaux/status/") else { return false }
            return record.type == "globalReset" || record.resetEffect != nil
        }
        let events=feed.map { TiboResetResearchEvent.fromFeed($0) }
        let cadence=TiboResetCadence(events:events,now:now)
        let estimates=cadence.cohorts.compactMap(\.announcementEstimate).filter { !$0.isPast }
        tiboEstimate=estimates.map { $0.earliest.addingTimeInterval($0.latest.timeIntervalSince($0.earliest)/2) }
            .filter { $0 > now && $0 < (window?.resetDate ?? .distantPast) }.min()
        let tibo: String
        if !model.reminders.acceptsResetMessages { tibo=L("接收重置消息已关闭", "Reset messages are off") }
        else if let cohort=cadence.cohorts.first(where: { $0.hasSufficientHistory }),let interval=cohort.medianInterval {
            tibo=L("\(cohort.sampleCount) 次公告 · 间隔中位数 \(UsageForecastFormat.number(interval/86400)) 天", "\(cohort.sampleCount) announcements · median interval \(UsageForecastFormat.number(interval/86400)) days")
        } else { tibo=L("样本不足，暂不估计", "Not enough history to estimate") }
        if tiboSummary != tibo { tiboSummary=tibo }
        let history=feed.map { UsageForecastHistoryRow(id:$0.id,date:$0.publishedAt,title:$0.title,
            detail:$0.timestampBasis == .collected ? L("收录时间 · "+$0.body,"Collected · "+$0.body) : $0.body,sourceURL:$0.sourceURL) }
        if tiboHistoryRows != history { tiboHistoryRows=history }
        let records=model.forecastEvaluations.filter { $0.prediction.windowID == window?.windowID }.sorted { $0.prediction.issuedAt > $1.prediction.issuedAt }
        let rows=records.map { row -> UsageForecastHistoryRow in
            let label: String,detail: String
            switch row.evaluation {
            case .pending: label=L("等待后续观察", "Awaiting observations");detail=L("预计用尽：", "Predicted depletion: ")+(row.prediction.predictedExhaustionAt.map(UsageForecastFormat.date) ?? "—")
            case .scored(let score):
                label=L("已观察到额度用尽", "Depletion observed")
                detail=L("时间误差范围：", "Timing error range: ")+UsageForecastFormat.number(score.minimumAbsoluteError/60)+"–"+UsageForecastFormat.number(score.maximumAbsoluteError/60)+L(" 分钟", " minutes")
            case .censored(let reason):
                label=L("未计入评估", "Excluded from evaluation")
                switch reason {
                case .resetBeforeDepletion: detail=L("额度用尽前已重置", "Reset before depletion")
                case .observationGap,.staleObservations: detail=L("观察记录不连续", "Observations are incomplete")
                case .quotaChanged,.contextChanged: detail=L("额度或使用环境已变化", "Quota or usage context changed")
                default: detail=L("缺少可核对的后续记录", "No verifiable follow-up")
                }
            }
            return .init(id:row.id,date:row.prediction.issuedAt,title:label,detail:detail,sourceURL:nil)
        }
        if evaluationRows != rows { evaluationRows=rows }
        let summary=UsageForecastEvaluationSummary(records:records)
        let text=summary.closedCycleCount > 0
            ? L("\(summary.closedCycleCount) 个完整周期 · \(summary.scoredCount) 条已核对", "\(summary.closedCycleCount) completed cycles · \(summary.scoredCount) evaluated")
            : summary.pendingCount > 0 ? L("\(summary.pendingCount) 条等待核对", "\(summary.pendingCount) awaiting evaluation")
            : L("积累观察后可查看", "Available after observations accumulate")
        if evaluationSummary != text { evaluationSummary=text }
    }
}

@MainActor enum UsageForecastFormat {
    private static var context=""
    private static var dates=[String:DateFormatter]()
    private static var numbers=[Int:NumberFormatter]()
    private static func dateFormatter(_ template: String) -> DateFormatter {
        let key=Locale.autoupdatingCurrent.identifier+"|"+TimeZone.autoupdatingCurrent.identifier
        if key != context { context=key;dates.removeAll();numbers.removeAll() }
        if let cached=dates[template] { return cached }
        let result=DateFormatter();result.locale = .autoupdatingCurrent;result.timeZone = .autoupdatingCurrent
        result.setLocalizedDateFormatFromTemplate(template);dates[template]=result;return result
    }
    static func date(_ date: Date) -> String { dateFormatter("MMMdjmm").string(from:date) }
    static func day(_ date:Date)->String {dateFormatter("MMMd").string(from:date)}
    static func time(_ date: Date) -> String { dateFormatter("jmm").string(from:date) }
    static func number(_ value: Double?,digits: Int = 1) -> String {
        guard let value,value.isFinite else { return "—" }
        _=dateFormatter("MMMd")
        if numbers[digits] == nil {
            let result=NumberFormatter();result.locale = .autoupdatingCurrent;result.numberStyle = .decimal
            result.maximumFractionDigits=digits;result.minimumFractionDigits=0;result.usesGroupingSeparator=false;numbers[digits]=result
        }
        return numbers[digits]?.string(from:NSNumber(value:value)) ?? "—"
    }
    static func percent(_ value: Double?,digits: Int = 1) -> String {
        guard let value,value.isFinite else { return "—" }
        return number(value,digits:digits)+"%"
    }
    static func pace(_ value: Double?,approximate: Bool = false) -> String {
        guard let value,value.isFinite else { return "—" }
        return (approximate ? L("约", "≈ ") : "")+percent(value)+L(" / 小时", " / hour")
    }
}
