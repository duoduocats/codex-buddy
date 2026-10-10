import AppKit
import SwiftUI

enum UsagePreviewPart: String, CaseIterable, Hashable {
    case theme, display, messages, resets, chart, sharing, menu
}
enum UsagePreviewAnchor: Hashable {
    case control(UsagePreviewPart), target(UsagePreviewPart)
}
private struct UsagePreviewEnabled: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var usagePreviewEnabled: Bool {
        get { self[UsagePreviewEnabled.self] }
        set { self[UsagePreviewEnabled.self] = newValue }
    }
}
struct UsagePreviewAnchors: PreferenceKey {
    static var defaultValue: [UsagePreviewAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UsagePreviewAnchor: Anchor<CGRect>], nextValue: () -> [UsagePreviewAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(),uniquingKeysWith:{ _, next in next })
    }
}
private struct UsagePreviewAnchorModifier: ViewModifier {
    let key: UsagePreviewAnchor
    @Environment(\.usagePreviewEnabled) private var enabled
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.anchorPreference(key:UsagePreviewAnchors.self,value:.bounds) { [key:$0] } }
        else { content }
    }
}
extension View {
    func usagePreviewAnchor(_ key: UsagePreviewAnchor) -> some View { modifier(UsagePreviewAnchorModifier(key:key)) }
}

struct UsagePreviewConnection: Identifiable {
    let id: UsagePreviewPart
    let start: CGPoint
    let end: CGPoint
    let detourY: CGFloat?
    var path: Path {
        Path { path in
            path.move(to:start)
            if let y = detourY {
                let direction: CGFloat = start.x > end.x ? -1 : 1
                let bend = start.x + direction * 18
                path.addCurve(to:CGPoint(x:bend,y:y),control1:CGPoint(x:bend,y:start.y),control2:CGPoint(x:bend,y:y))
                path.addLine(to:CGPoint(x:end.x,y:y))
                path.addLine(to:end)
            } else {
                let middle = (start.x + end.x) / 2
                path.addCurve(to:end,control1:CGPoint(x:middle,y:start.y),control2:CGPoint(x:middle,y:end.y))
            }
        }
    }
}
enum UsagePreviewConnections {
    // Both menu controls address the same rendered glyph. Missing targets never get a fallback line.
    static func resolve(_ frames: [UsagePreviewAnchor: CGRect]) -> [UsagePreviewConnection] {
        UsagePreviewPart.allCases.compactMap { part in
            let target: UsagePreviewPart = part == .theme || part == .display ? .menu : part
            guard let control = frames[.control(part)], let region = frames[.target(target)],
                  control.width > 0, region.width > 0 else { return nil }
            let fromLeft = control.midX < region.midX
            let start = CGPoint(x:fromLeft ? control.maxX : control.minX,y:control.midY)
            let end = part == .sharing ? CGPoint(x:region.midX,y:region.minY)
                : CGPoint(x:fromLeft ? region.minX : region.maxX,y:region.midY)
            let detour = part == .sharing ? frames[.target(.chart)].map { $0.minY - 50 } : nil
            return UsagePreviewConnection(id:part,start:start,end:end,detourY:detour)
        }
    }
}
@MainActor final class UsagePreviewHighlight: ObservableObject {
    @Published private(set) var part: UsagePreviewPart? = .theme
    func setHovered(_ value: UsagePreviewPart?) {
        let next = value ?? .theme
        if next != part { part = next }
    }
}
struct UsagePreviewLines: View {
    let frames: [UsagePreviewAnchor: CGRect]
    @ObservedObject var highlight: UsagePreviewHighlight
    var framesChanged: ([UsagePreviewAnchor: CGRect]) -> Void = { _ in }
    var body: some View {
        ZStack {
            ForEach(UsagePreviewConnections.resolve(frames)) { link in
                let color = highlight.part == link.id ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.30)
                link.path.stroke(color,style:StrokeStyle(lineWidth:1,lineCap:.round,lineJoin:.round))
                Circle().fill(color).frame(width:4,height:4).position(link.start)
                Circle().fill(color).frame(width:4,height:4).position(link.end)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { framesChanged(frames) }.onChange(of:frames) { framesChanged($0) }
    }
}

// All preview data and preferences stay in memory. The sample model is never started.
final class UsagePreviewPreferences: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey:key) }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func dictionaryRepresentation() -> [String: Any] { values }
}
struct UsagePreviewStyle: Equatable {
    let theme: MenuBarTheme
    let percentage, messages, resets, activities, details, soonest, chart, sharing: Bool
    let expiryDays: Int
    @MainActor init(_ model: AppModel) {
        theme = model.menuBarTheme;percentage = model.menuShowsPercentage
        messages = model.reminders.messagesEnabled;resets = model.reminders.resetMessagesEnabled
        activities = model.reminders.activityMessagesEnabled;details = model.showResetDetails
        soonest = model.resetDetailsOnlySoonest;expiryDays = model.resetExpiryWindowDays
        chart = model.showDailyTokenUsage;sharing = model.showUsageShareButton
    }
}
private func usagePreviewDate() -> Date {
    var calendar = Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
    return calendar.date(from:DateComponents(year:2026,month:10,day:9,hour:21,minute:0))!
}
@MainActor final class UsagePreviewModel: ObservableObject {
    let model: AppModel
    let updates: UpdateManager
    private var appliedStyle: UsagePreviewStyle?
    init(now: Date = usagePreviewDate()) {
        let preferences = UsagePreviewPreferences()
        model = AppModel(preferences:preferences,client:UsageClient(credentialProvider:{ nil }))
        updates = UpdateManager(defaults:preferences,repository:"")
        model.useDemo();model.now = now;model.updated = now;model.statisticsUpdated = now
        model.usage = UsageResponse(rateLimits:LimitBucket(limitId:"codex",limitName:nil,
            primary:LimitWindow(usedPercent:32,windowDurationMins:10080,resetsAt:now.addingTimeInterval(57*3_600).timeIntervalSince1970),
            secondary:nil,planType:"sample"),rateLimitsByLimitId:nil,rateLimitResetCredits:ResetCredits(availableCount:3))
        model.statistics = .demo(now:now);model.resetCreditDetails = .demo(now:now,count:3)
        model.reminders.useDemo(now:now,status:nil)
        model.reminders.setActivityMessages([ResetAnnouncement(id:"activity-preview",revision:1,type:"activity",status:.completed,
            publishedAt:min(now,Calendar.autoupdatingCurrent.date(bySettingHour:3,minute:15,second:0,of:now)!),
            expiresAt:now.addingTimeInterval(86_400),
            titleText:.init(zh:"Tibo 的 28 天挑战",en:"Tibo’s 28-day challenge"),
            bodyText:.init(zh:"第 4 天 · 即时调整方向与 Sol Ultrafast",en:"Day 4 · Instant steering and Sol Ultrafast"),
            sourceURL:URL(string:"https://x.com/thsottiaux/status/2108275041276420573"))])
    }
    func apply(_ style: UsagePreviewStyle) {
        guard style != appliedStyle else { return }
        let previous = appliedStyle
        appliedStyle = style
        // Only changed fields notify SwiftUI; appearance-only edits do not reset message state.
        if model.menuBarTheme != style.theme { model.menuBarTheme = style.theme }
        if model.menuShowsPercentage != style.percentage { model.menuShowsPercentage = style.percentage }
        if model.showResetDetails != style.details { model.showResetDetails = style.details }
        if model.resetDetailsOnlySoonest != style.soonest { model.resetDetailsOnlySoonest = style.soonest }
        if model.resetExpiryWindowDays != style.expiryDays { model.resetExpiryWindowDays = style.expiryDays }
        if model.showDailyTokenUsage != style.chart { model.showDailyTokenUsage = style.chart }
        if model.showUsageShareButton != style.sharing { model.showUsageShareButton = style.sharing }
        model.reminders.setMessagesEnabled(style.messages)
        model.reminders.setResetMessagesEnabled(style.resets);model.reminders.setActivityMessagesEnabled(style.activities)
        if previous == nil || previous?.activities != style.activities {
            let resetSample = ResetAnnouncement(id:"preview-reset",revision:1,type:"message",status:.completed,
                publishedAt:model.now,expiresAt:model.now.addingTimeInterval(86_400),
                titleText:.init(zh:"额度重置已完成",en:"Quota reset complete"),
                bodyText:.init(zh:"可刷新查看当前额度。",en:"Refresh to see your current quota."))
            model.reminders.useDemo(now:model.now,status:nil,messages:style.activities ? [] : [resetSample])
        }
    }
}

struct UsagePreviewCanvas: View {
    @ObservedObject var model: AppModel
    let updates: UpdateManager
    @Environment(\.colorScheme) private var scheme
    private var clock: String {
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from:model.now)
    }
    var body: some View {
        VStack(spacing:14) {
            HStack(spacing:14) {
                Image(nsImage:DuoDrawing.image(size:NSSize(width:38,height:30),window:model.window,credits:model.credits,
                    now:model.now,menu:true,dark:scheme == .dark,menuShowsPercentage:model.menuShowsPercentage,menuTheme:model.menuBarTheme))
                    .frame(width:38,height:30).usagePreviewAnchor(.target(.menu))
                Spacer()
                Image(systemName:"wifi").font(.system(size:12))
                Image(systemName:"battery.100").font(.system(size:17))
                Text(clock).font(.system(size:12,weight:.medium)).monospacedDigit()
            }.padding(.horizontal,16).frame(width:380,height:40)
                .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
                .accessibilityLabel(L("顶栏预览", "Menu bar preview"))
            UsageView(model:model,settings:{},updates:updates)
                .background(Color(nsColor:.windowBackgroundColor),in:RoundedRectangle(cornerRadius:24,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:24).stroke(Color.primary.opacity(0.08),lineWidth:0.5))
                .shadow(color:.black.opacity(scheme == .dark ? 0.22 : 0.09),radius:12,y:6)
        }.allowsHitTesting(false).accessibilityElement(children:.combine)
            .accessibilityLabel(L("使用示例数据的效果预览", "Appearance preview using sample data"))
    }
}
