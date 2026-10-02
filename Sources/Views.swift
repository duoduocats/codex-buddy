import SwiftUI
import AppKit

struct UsageView: View {
    @ObservedObject var model: AppModel
    var settings: () -> Void
    var sharePresentationChanged: (Bool) -> Void = { _ in }
    @ObservedObject var updates: UpdateManager = .shared
    @StateObject private var chartRange = UsageChartRange()
    private var resetTime: String {
        guard let date = model.window?.resetDate else { return L("暂无数据", "Not available") }
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium;formatter.timeStyle = .short
        return formatter.string(from:date)
    }
    var body: some View {
        VStack(spacing:16) {
            HStack {
                if model.entries.count > 1 {
                    Picker(L("顶栏显示", "Menu bar display"),selection:$model.selection) {
                        ForEach(Array(model.entries.enumerated()),id:\.offset) { index,entry in Text(entry.0).tag(index) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                } else {
                    Text(model.entries.first?.0 ?? L("额度概览", "Usage overview"))
                        .font(.system(size:14,weight:.semibold))
                }
                Spacer(minLength:8)
                Text(model.refreshing ? L("更新中…", "Updating…") : model.stale ? L("数据待更新", "Out of date") : model.updated == nil ? L("等待连接", "Connecting") : L("已同步", "Up to date"))
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
            ResetAnnouncementCard(manager:model.reminders,now:model.now)
            HStack(spacing:22) {
                DuoIcon(model:model,compact:true)
                VStack(alignment:.leading,spacing:18) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(model.window.map { String(format:"%.0f%%",$0.remaining) } ?? "—")
                            .font(.system(size:36,weight:.semibold)).monospacedDigit()
                        Text(L("剩余额度", "Remaining quota")).font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    VStack(alignment:.leading,spacing:3) {
                        Text(model.credits.map(String.init) ?? "—").font(.system(size:23,weight:.semibold)).monospacedDigit()
                        Text(L("次可用重置", "Available resets")).font(.system(size:11)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack(alignment:.firstTextBaseline) {
                Text(L("下次重置", "Next reset")).foregroundStyle(.secondary)
                Spacer(minLength:8)
                Text(resetTime).multilineTextAlignment(.trailing)
            }.font(.system(size:12))
            if let error = model.error {
                Text(error).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if model.usage == nil {
                    Button(L("打开 ChatGPT / Codex 登录", "Open ChatGPT / Codex")) {
                        for name in ["ChatGPT","Codex"] {
                            let url = URL(fileURLWithPath:"/Applications/\(name).app")
                            if FileManager.default.fileExists(atPath:url.path) { NSWorkspace.shared.open(url);break }
                        }
                    }.buttonStyle(.link)
                }
            }
            if model.showDailyTokenUsage {
                Divider()
                DailyUsageChart(statistics:model.statistics,refreshing:model.statisticsRefreshing,now:model.now,days:$chartRange.days,allowsSharing:model.showUsageShareButton,sharePresentationChanged:sharePresentationChanged)
                if let error = model.statisticsError {
                    Text(error).font(.system(size:11)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                }
                UsageStatisticsRow(statistics:model.statistics)
            }
            Divider()
            HStack {
                Button { model.refresh() } label: { Image(systemName:"arrow.clockwise") }
                    .disabled(model.refreshing || model.statisticsRefreshing).help(L("刷新额度和统计", "Refresh quota and statistics"))
                if let date = model.updated { Text(date,style:.time).font(.system(size:10)).foregroundStyle(.secondary) }
                Spacer()
                PanelUpdateButton(updates:updates)
                Button { settings() } label: { Image(systemName:"gearshape") }.help(L("设置", "Settings"))
                Button { NSApp.terminate(nil) } label: { Image(systemName:"power") }.help(L("退出", "Quit"))
            }.buttonStyle(.borderless)
        }.padding(20).frame(width:380).fixedSize(horizontal:false,vertical:true)
    }
}

struct UsageStatisticsRow: View {
    var statistics: UsageStatistics?
    var body: some View {
        let s = statistics
        return HStack(alignment:.top,spacing:8) {
            metric(StatisticsFormat.tokens(s?.lifetimeTokens),L("累计 Token", "Lifetime\ntokens"))
            metric(StatisticsFormat.tokens(s?.peakDailyTokens),L("单日峰值", "Peak\nday"))
            metric(StatisticsFormat.duration(s?.longestRunningTurnSec),L("最长任务", "Longest\ntask"))
            metric(StatisticsFormat.days(s?.longestStreakDays),L("最长连续", "Longest\nstreak"))
            metric(StatisticsFormat.days(s?.currentStreakDays),L("当前连续", "Current\nstreak"))
        }.frame(maxWidth:.infinity)
    }
    private func metric(_ value: String, _ title: String) -> some View {
        VStack(spacing:5) {
            Text(value).font(.system(size:15,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.system(size:10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(height:AppLanguage.chinese ? 14 : 26,alignment:.top)
        }.frame(maxWidth:.infinity)
            .accessibilityElement(children:.ignore).accessibilityLabel("\(title.replacingOccurrences(of:"\n",with:" ")): \(value)")
    }
}

struct SettingsView: View {
    static let width: CGFloat = 440
    @ObservedObject var model: AppModel
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @StateObject var login = LoginModel()
    @ObservedObject var updates: UpdateManager = .shared
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:14) {
                if let icon = BuddyBrand.settingsIcon {
                    Image(nsImage:icon).resizable().interpolation(.high)
                        .frame(width:56,height:56)
                        .accessibilityHidden(true)
                }
                Text("Codex Buddy").font(.system(size:18,weight:.semibold)).lineLimit(1)
                Spacer(minLength:0)
            }.padding(.vertical,12)
            Divider()
            VStack(spacing:0) {
                HStack {
                    Text(L("顶栏主题", "Theme"))
                    Spacer(minLength:12)
                    SettingsSegments(labels:MenuBarTheme.allCases.map(\.title),selection:Binding(
                        get:{model.menuBarTheme == .ring ? 0 : 1},
                        set:{model.menuBarTheme = $0 == 0 ? .ring : .duoDuoCat}),
                        accessibilityLabel:L("顶栏主题", "Theme"))
                        .frame(width:164,height:24)
                }.frame(height:38)
                HStack {
                    Text(L("显示内容", "Display"))
                    Spacer(minLength:12)
                    SettingsSegments(labels:[L("时间", "Time"),L("百分比", "Percentage")],selection:Binding(
                        get:{model.menuShowsPercentage ? 1 : 0},
                        set:{model.menuShowsPercentage = $0 == 1}),
                        accessibilityLabel:L("显示内容", "Display"))
                        .frame(width:164,height:24)
                }.frame(height:38)
            }.padding(.vertical,8)
            Divider()
            VStack(spacing:0) {
                switchRow(L("每日 Token 用量", "Daily token usage"),selection:$model.showDailyTokenUsage)
                switchRow(L("用量分享按钮", "Usage sharing button"),selection:$model.showUsageShareButton)
                    .disabled(!model.showDailyTokenUsage)
            }.padding(.vertical,8)
            Divider()
            VStack(alignment:.leading,spacing:0) {
                MessageReminderToggle(manager:model.reminders).padding(.top,7)
                switchRow(L("开机启动", "Launch at login"),selection:Binding(get:{login.enabled},set:{login.set($0)}))
                    .padding(.vertical,7)
                if let message = login.message {
                    Text(message).font(.system(size:11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true).padding(.bottom,12)
                }
            }
            Divider()
            SettingsUpdateSection(updates:updates)
        }.font(.system(size:13)).controlSize(.regular)
            .padding(.horizontal,18).frame(width:Self.width)
            .background(Color(nsColor:.windowBackgroundColor))
            .fixedSize(horizontal:false,vertical:true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key:SettingsHeightKey.self,value:proxy.size.height)
            })
            .onPreferenceChange(SettingsHeightKey.self,perform:onHeightChange)
    }
    private func switchRow(_ title: String,selection: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength:12)
            Toggle(title,isOn:selection).labelsHidden().toggleStyle(.switch)
        }.frame(height:38)
    }
}

private struct SettingsSegments: NSViewRepresentable {
    var labels: [String]
    @Binding var selection: Int
    var accessibilityLabel: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels:labels,trackingMode:.selectOne,
            target:context.coordinator,action:#selector(Coordinator.select(_:)))
        control.segmentDistribution = .fillEqually
        for index in labels.indices { control.setWidth(164 / CGFloat(labels.count),forSegment:index) }
        control.font = .systemFont(ofSize:13)
        control.setAccessibilityLabel(accessibilityLabel)
        return control
    }
    func updateNSView(_ control:NSSegmentedControl,context:Context) {
        context.coordinator.parent = self
        control.selectedSegment = selection
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSSegmentedControl,context:Context) -> CGSize? {
        CGSize(width:164,height:24)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: SettingsSegments
        init(_ parent:SettingsSegments) { self.parent = parent }
        @objc func select(_ control:NSSegmentedControl) {
            guard parent.labels.indices.contains(control.selectedSegment) else { return }
            parent.selection = control.selectedSegment
        }
    }
}

private struct SettingsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat,nextValue: () -> CGFloat) { value = nextValue() }
}
