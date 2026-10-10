import SwiftUI
import AppKit

struct UsageView: View {
    @ObservedObject var model: AppModel
    var settings: () -> Void
    var openChallenge: () -> Void = {}
    var sharePresentationChanged: (Bool) -> Void = { _ in }
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
    var messagePresentationChanged: (Bool) -> Void = { _ in }
    @ObservedObject var updates: UpdateManager = .shared
    @StateObject private var chartRange = UsageChartRange()
    private var resetTime: String {
        guard let date = model.window?.resetDate else { return L("暂无数据", "Not available") }
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium;formatter.timeStyle = .short
        return formatter.string(from:date)
    }
    var body: some View {
        VStack(spacing:22) {
            MessageCenterView(manager:model.reminders,now:model.now,openChallenge:openChallenge,
                presentationChanged:messagePresentationChanged)
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
                HStack(spacing:5) {
                    Circle().fill(model.stale ? Color.orange : model.updated == nil ? Color.secondary : Color.green)
                        .frame(width:5,height:5).accessibilityHidden(true)
                    Text(model.refreshing ? L("更新中…", "Updating…") : model.stale ? L("待更新", "Out of date") : model.updated == nil ? L("连接中", "Connecting") : L("已同步", "Up to date"))
                        .font(.system(size:10)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing:10) {
                HStack(spacing:20) {
                    DuoIcon(model:model,compact:true)
                    VStack(alignment:.leading,spacing:16) {
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.window.map { String(format:"%.0f%%",$0.remaining) } ?? "—")
                                .font(.system(size:34,weight:.semibold)).monospacedDigit()
                            Text(L("剩余额度", "Remaining quota")).font(.system(size:11)).foregroundStyle(.secondary)
                        }
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.credits.map(String.init) ?? "—").font(.system(size:23,weight:.semibold)).monospacedDigit()
                            Text(L("次可用重置", "Available resets")).font(.system(size:11)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    Text(L("下次重置", "Next reset")).foregroundStyle(.secondary)
                    Spacer(minLength:8)
                    Text(resetTime).monospacedDigit().multilineTextAlignment(.trailing)
                }.font(.system(size:11))
            }
            if model.showResetDetails {
                ResetCreditDetailsView(model:model)
                    .usagePreviewAnchor(.target(.resets))
            }
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
                DailyUsageChart(statistics:model.statistics,refreshing:model.statisticsRefreshing,now:model.now,days:$chartRange.days,allowsSharing:model.showUsageShareButton,sharePresentationChanged:sharePresentationChanged)
                if let error = model.statisticsError {
                    Text(error).font(.system(size:11)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                }
                UsageStatisticsRow(statistics:model.statistics)
            }
            HStack {
                Button { model.refresh() } label: { Image(systemName:"arrow.clockwise") }
                    .disabled(model.refreshing || model.statisticsRefreshing).help(L("刷新额度和统计", "Refresh quota and statistics"))
                if let date = model.updated { Text(date,style:.time).font(.system(size:10)).foregroundStyle(.secondary) }
                Spacer()
                PanelUpdateButton(updates:updates)
                Button { settings() } label: { Image(systemName:"gearshape") }.help(L("打开主面板", "Open main window"))
                Button { NSApp.terminate(nil) } label: { Image(systemName:"power") }.help(L("退出", "Quit"))
            }.buttonStyle(.borderless)
        }.padding(20).frame(width:380).fixedSize(horizontal:false,vertical:true)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { contentHeightChanged(geometry.size.height) }
                    .onChange(of:geometry.size.height) { height in contentHeightChanged(height) }
            })
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
            Text(value).font(.system(size:14,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.system(size:10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(height:AppLanguage.chinese ? 14 : 26,alignment:.top)
        }.frame(maxWidth:.infinity)
            .accessibilityElement(children:.ignore).accessibilityLabel("\(title.replacingOccurrences(of:"\n",with:" ")): \(value)")
    }
}
