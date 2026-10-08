import SwiftUI

/// Announcements share one compact row with local time; scheduled messages also include a countdown.
struct ResetAnnouncementCard: View {
    @ObservedObject var manager: ResetReminderManager
    var now: Date = Date()

    var body: some View {
        if let message = manager.panelAnnouncement(at:now) {
            HStack(alignment:.top,spacing:9) {
                Image(systemName:"bell").font(.system(size:11,weight:.medium))
                    .frame(height:22)
                    .accessibilityHidden(true)
                VStack(alignment:.leading,spacing:2) {
                    HStack(spacing:8) {
                        Text(message.title).font(.system(size:11,weight:.medium))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength:8)
                        if let date = message.scheduledAt {
                            Text(countdown(to:date)).font(.system(size:11)).monospacedDigit()
                                .fixedSize(horizontal:true,vertical:false)
                        }
                    }.frame(minHeight:22)
                    Text(message.timeDescription()).font(.system(size:11)).monospacedDigit()
                        .fixedSize(horizontal:false,vertical:true)
                }
                    .help(description(for:message))
                    .accessibilityElement(children:.combine)
                    .accessibilityLabel(description(for:message))
                Button { manager.dismissPanelAnnouncement() } label: {
                    Image(systemName:"xmark").font(.system(size:9,weight:.medium))
                        .frame(width:20,height:22)
                }.buttonStyle(.plain)
                    .help(L("本次运行隐藏，重启后恢复", "Hide until the app restarts"))
                    .accessibilityLabel(L("隐藏消息，重启后恢复", "Hide message until restart"))
            }.foregroundStyle(.secondary).frame(minHeight:22)
                .padding(10).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
        }
    }
    private func countdown(to date: Date) -> String {
        let minutes = max(0,Int(date.timeIntervalSince(now) / 60))
        let days = minutes / 1440, hours = (minutes % 1440) / 60, remainder = minutes % 60
        let value: String
        if days > 0 { value = hours > 0 ? L("\(days)天\(hours)小时", "\(days)d \(hours)h") : L("\(days)天", "\(days)d") }
        else if hours > 0 { value = remainder > 0 ? L("\(hours)小时\(remainder)分钟", "\(hours)h \(remainder)m") : L("\(hours)小时", "\(hours)h") }
        else { value = remainder > 0 ? L("\(remainder)分钟", "\(remainder)m") : L("不到1分钟", "<1m") }
        return L("还有 \(value)", "In \(value)")
    }
    private func description(for message: ResetAnnouncement) -> String {
        [message.title,message.body,message.timeDescription(),message.appliesTo]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator:"\n")
    }
}

struct PanelMessageSettings: View {
    @ObservedObject var manager: ResetReminderManager
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            SettingsToggleRow(title:L("消息通知", "Messages"),
                detail:L("接收并显示所选类型的消息。", "Receive and display the selected message types."),
                selection:Binding(get:{manager.messagesEnabled},set:{manager.setMessagesEnabled($0)}))
            VStack(spacing:8) {
                category(L("重置提醒", "Reset reminders"),selection:Binding(
                    get:{manager.resetMessagesEnabled},set:{manager.setResetMessagesEnabled($0)}))
                category(L("活动消息", "Activity messages"),selection:Binding(
                    get:{manager.activityMessagesEnabled},set:{manager.setActivityMessagesEnabled($0)}))
            }.padding(.leading,16).disabled(!manager.messagesEnabled)
        }
    }
    private func category(_ title:String,selection:Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size:12,weight:.medium))
            Spacer(minLength:12)
            Toggle(title,isOn:selection).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.frame(minHeight:28)
    }
}

struct SystemReminderSettings: View {
    @ObservedObject var manager: ResetReminderManager
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            SettingsToggleRow(title:L("系统提醒", "System alerts"),
                detail:manager.acceptsAnyMessages
                    ? L("按消息类型设置推送到通知中心。", "Send the selected message types to Notification Center.")
                    : L("开启消息通知并选择消息类型后可用。", "Enable messages and select a type first."),
                selection:Binding(get:{manager.acceptsAnyMessages && manager.enabled},set:{manager.setEnabled($0)}))
                .disabled(!manager.acceptsAnyMessages)
            if let message = manager.message {
                Text(message).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
}

typealias MessageReminderSettings = SystemReminderSettings

struct MessageCenterView: View {
    @ObservedObject var manager: ResetReminderManager
    var now: Date
    var openChallenge: () -> Void
    @State private var expanded = false
    var body: some View {
        let messages = manager.panelAnnouncements(at:now)
        if !messages.isEmpty {
            VStack(alignment:.leading,spacing:10) {
                HStack {
                    Text(L("消息", "Messages")).font(.system(size:13,weight:.semibold))
                    Spacer()
                    if messages.count > 1 {
                        Button { expanded.toggle() } label: {
                            HStack(spacing:4) {
                                Text(L("\(messages.count) 条", "\(messages.count) messages"))
                                Image(systemName:expanded ? "chevron.up" : "chevron.down")
                            }.font(.system(size:10))
                        }.buttonStyle(.plain).help(L("展开或收起消息", "Expand or collapse messages"))
                            .accessibilityIdentifier("message-center-toggle")
                    }
                }
                ForEach(expanded ? messages : Array(messages.prefix(1))) { message in
                    MessageCenterCard(message:message,now:now,
                        open:{ message.type == "activity" ? openChallenge() : manager.openSource(for:message) },
                        dismiss:{manager.dismissPanelMessage(message.id)})
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}

private struct MessageCenterCard: View {
    var message: ResetAnnouncement
    var now: Date
    var open: () -> Void
    var dismiss: () -> Void
    private var shortTime: String {
        let date = message.scheduledAt ?? message.publishedAt
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = .autoupdatingCurrent
        let includeYear = Calendar.autoupdatingCurrent.component(.year,from:date) != Calendar.autoupdatingCurrent.component(.year,from:now)
        formatter.setLocalizedDateFormatFromTemplate(includeYear ? "yMMMdjmmz" : "MMMdjmmz")
        let value = formatter.string(from:date)
        if message.scheduledAt != nil { return L("预计 \(value)", "Expected \(value)") }
        return message.timestampBasis == .collected ? L("收录于 \(value)", "Collected \(value)") : L("发布于 \(value)", "Published \(value)")
    }
    var body: some View {
        Button(action:open) {
            HStack(alignment:.top,spacing:10) {
                Image(systemName:message.type == "activity" ? "calendar" : "arrow.clockwise.circle")
                    .font(.system(size:19,weight:.medium)).foregroundStyle(Color.accentColor)
                    .frame(width:28,height:30).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:5) {
                    HStack(alignment:.top,spacing:8) {
                        Text(message.title).font(.system(size:13,weight:.semibold)).lineLimit(1)
                        Spacer(minLength:4)
                        Color.clear.frame(width:16,height:17)
                    }
                    Text(message.body.components(separatedBy:"\n").first ?? message.body)
                        .font(.system(size:11,weight:.medium)).lineLimit(1).foregroundStyle(Color.primary)
                    if let deadline = message.scheduledAt {
                        Text(L("还有 \(LimitWindow(usedPercent:0,windowDurationMins:nil,resetsAt:deadline.timeIntervalSince1970).detailCountdown(now:now))",
                               "In \(LimitWindow(usedPercent:0,windowDurationMins:nil,resetsAt:deadline.timeIntervalSince1970).detailCountdown(now:now))"))
                            .font(.system(size:11,weight:.medium)).monospacedDigit()
                    }
                    HStack(alignment:.top,spacing:6) {
                        Text(shortTime).font(.system(size:10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal:false,vertical:true)
                        Spacer(minLength:4)
                        if message.sourceURL != nil {
                            Text(message.type == "activity" ? L("查看活动 ›", "View activity ›") : L("查看原帖 ›", "View source ›"))
                                .font(.system(size:10,weight:.medium)).foregroundStyle(Color.primary).fixedSize()
                        }
                    }
                }
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                .background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:12,style:.continuous))
                .contentShape(RoundedRectangle(cornerRadius:12,style:.continuous))
        }.buttonStyle(.plain)
            .accessibilityIdentifier("message-card-"+message.id)
            .overlay(alignment:.topTrailing) {
                Button(action:dismiss) { Image(systemName:"xmark").font(.system(size:9)).frame(width:16,height:17) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(12)
                    .help(L("本次运行隐藏，重启后恢复", "Hide until the app restarts"))
                    .accessibilityLabel(L("隐藏消息，重启后恢复", "Hide message until restart"))
            }
            .help([message.title,message.body,message.timeDescription(),message.appliesTo].filter { !$0.isEmpty }.joined(separator:"\n"))
    }
}
