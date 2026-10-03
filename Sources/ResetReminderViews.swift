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

struct MessageReminderSettings: View {
    @ObservedObject var manager: ResetReminderManager
    var body: some View {
        SettingsGroup {
            SettingsToggleRow(title:L("接收消息", "Receive messages"),
                detail:L("接收公告和提醒，在面板中查看。", "Receive announcements and reminders in the panel."),
                selection:Binding(get:{manager.messagesEnabled},set:{manager.setMessagesEnabled($0)}))
            Divider().padding(.vertical,10).padding(.leading,22)
            SettingsToggleRow(title:L("系统通知", "System notifications"),
                detail:manager.messagesEnabled
                    ? L("收到消息时，通过通知中心推送提醒。", "Show an alert in Notification Center when a message arrives.")
                    : L("开启“接收消息”后，可使用系统通知。", "Enable Receive messages to use system notifications."),
                selection:Binding(get:{manager.messagesEnabled && manager.enabled},set:{manager.setEnabled($0)}))
                .disabled(!manager.messagesEnabled)
                .padding(.leading,22)
            if let message = manager.message {
                Text(message).font(.system(size:11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true).padding(.top,10)
            }
        }
    }
}
