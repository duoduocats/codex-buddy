import SwiftUI

/// Announcements share one compact row; time-sensitive messages may show a countdown.
struct ResetAnnouncementCard: View {
    @ObservedObject var manager: ResetReminderManager
    var now: Date = Date()

    var body: some View {
        if let message = manager.panelAnnouncement(at:now) {
            HStack(spacing:9) {
                Image(systemName:"bell").font(.system(size:11,weight:.medium))
                    .accessibilityHidden(true)
                Text(message.title).font(.system(size:11,weight:.medium))
                    .lineLimit(1).truncationMode(.tail)
                    .help(description(for:message))
                    .accessibilityLabel(description(for:message))
                Spacer(minLength:8)
                if let date = message.scheduledAt {
                    Text(countdown(to:date)).font(.system(size:11)).monospacedDigit()
                        .fixedSize(horizontal:true,vertical:false)
                }
                Button { manager.dismissPanelAnnouncement() } label: {
                    Image(systemName:"xmark").font(.system(size:9,weight:.medium))
                        .frame(width:20,height:22)
                }.buttonStyle(.plain)
                    .help(L("本次运行隐藏，重启后恢复", "Hide until the app restarts"))
                    .accessibilityLabel(L("隐藏消息，重启后恢复", "Hide message until restart"))
            }.foregroundStyle(.secondary).frame(minHeight:22)
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
        [message.title,message.body,message.scheduledAt == nil ? nil : message.dateText,message.appliesTo]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator:"\n")
    }
}

struct MessageReminderToggle: View {
    @ObservedObject var manager: ResetReminderManager
    var body: some View {
        HStack {
            Text(L("消息提醒", "Message reminders"))
            Spacer(minLength:12)
            Toggle(L("消息提醒", "Message reminders"),isOn:Binding(
                get:{manager.enabled},set:{manager.setEnabled($0)}))
                .labelsHidden().toggleStyle(.switch)
                .help(L("接收消息的系统通知", "Receive system notifications for messages"))
        }.frame(height:38)
    }
}
