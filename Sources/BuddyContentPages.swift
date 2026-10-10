import AppKit
import SwiftUI

struct BuddyEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing:14) {
            Image(systemName:symbol).font(.system(size:32,weight:.light)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.system(size:17,weight:.semibold))
            Text(detail).font(.system(size:13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:380)
        }.padding(40).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
struct RecentMessagesView: View {
    @ObservedObject var manager: ResetReminderManager
    @ObservedObject var challenge: TiboChallengeManager
    let now: Date
    @State private var activityPresented = false
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(alignment:.center,spacing:24) {
                BuddyPageHeading(title:L("消息", "Messages"))
                    .frame(maxWidth:.infinity,alignment:.leading)
                if manager.acceptsActivityMessages && challenge.enabled { activityButton }
            }.padding(.horizontal,32).padding(.top,28).padding(.bottom,24)
            if !manager.acceptsAnyMessages {
                BuddyEmptyState(symbol:"bubble.left",title:L("接收消息已关闭", "Messages are turned off"),
                    detail:L("在用量概览中开启消息通知并选择消息类型。", "Enable messages and select a type in Usage overview."))
            } else if manager.recentMessages().isEmpty {
                BuddyEmptyState(symbol:"tray",title:L("暂无消息", "No messages yet"),
                    detail:manager.checking ? L("正在获取最近公告…", "Checking recent announcements…") : L("收到的最近公告会显示在这里。", "Recent announcements will appear here when received."))
            } else {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:16) { ForEach(manager.recentMessages()) { message in messageCard(message) } }
                        .padding(.horizontal,32).padding(.bottom,32).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }.sheet(isPresented:$activityPresented) {
            VStack(spacing:0) {
                HStack {
                    Text(challenge.document.phase(at:now) == .history ? L("历史活动", "Past activity") : L("本期特别活动", "Current special activity"))
                        .font(.system(size:13,weight:.semibold))
                    Spacer()
                    Button { activityPresented = false } label: { Image(systemName:"xmark").frame(width:24,height:24) }
                        .buttonStyle(.plain).accessibilityLabel(L("关闭活动", "Close activity"))
                }.padding(.horizontal,24).padding(.vertical,16)
                Divider()
                TiboChallengeView(manager:challenge,embedded:true,currentTime:now)
            }.frame(width:860,height:720)
        }.onChange(of:manager.acceptsActivityMessages) { if !$0 { activityPresented = false } }
    }
    private var activityButton: some View {
        let historical = challenge.document.phase(at:now) == .history
        let day = min(28,max(1,challenge.document.currentDay(at:now)))
        return Button {
            activityPresented = true
            challenge.check(force:true)
        } label: {
            HStack(spacing:16) {
                ZStack {
                    if let image = BuddyBrand.activityCalendar {
                        Image(nsImage:image).resizable().interpolation(.high).scaledToFit().frame(width:88,height:88)
                        Text(historical ? "28" : String(format:"%02d",day))
                            .font(.system(size:27,weight:.bold,design:.rounded)).foregroundStyle(Color(red:0.36,green:0.23,blue:0.90))
                            .rotationEffect(.degrees(-9)).offset(x:8,y:13)
                    }
                }.frame(width:88,height:88).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:8) {
                    Text(historical ? L("历史活动", "Past activity") : L("特别活动", "Special activity")).font(.system(size:16,weight:.semibold))
                    Text(L("Tibo 的 28 天挑战", "Tibo’s 28-day challenge")).font(.system(size:12)).foregroundStyle(.white.opacity(0.85))
                    Label(historical ? L("回看记录", "View history") : L("查看本期", "View current"),systemImage:"arrow.right")
                        .font(.system(size:12,weight:.medium)).foregroundStyle(Color(red:0.43,green:0.66,blue:1))
                }
                Spacer(minLength:0)
            }.foregroundStyle(.white).padding(.horizontal,18).frame(width:336,height:112)
                .background(LinearGradient(colors:[Color(red:0.27,green:0.19,blue:0.43),Color(red:0.12,green:0.13,blue:0.24)],
                    startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:18))
                .overlay(RoundedRectangle(cornerRadius:18).stroke(Color(red:0.58,green:0.46,blue:0.84).opacity(0.7),lineWidth:0.7))
                .shadow(color:Color.purple.opacity(0.10),radius:12,y:5)
        }.buttonStyle(.plain).accessibilityIdentifier("special-activity-button")
    }
    private func messageCard(_ message: ResetAnnouncement) -> some View {
        HStack(alignment:.top,spacing:20) {
            Image(systemName:message.type == "activity" ? "calendar" : "arrow.clockwise.circle")
                .font(.system(size:25,weight:.medium)).foregroundStyle(Color.blue).frame(width:56,height:56)
                .background(Color.blue.opacity(0.12),in:RoundedRectangle(cornerRadius:12)).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:14) {
                HStack(alignment:.top) {
                    Text(message.title).font(.system(size:19,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:12)
                    Text(message.type == "activity" ? L("活动", "Activity") : L("公告", "Announcement"))
                        .font(.system(size:11,weight:.medium)).foregroundStyle(Color.blue)
                        .padding(.horizontal,12).padding(.vertical,5).background(Color.blue.opacity(0.06),in:Capsule())
                        .overlay(Capsule().stroke(Color.blue.opacity(0.30),lineWidth:0.6))
                }
                Text(message.body).font(.system(size:13)).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
                if !message.appliesTo.isEmpty { Text(message.appliesTo).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                HStack {
                    let published = message.timestampBasis == .collected ? L("收录于 \(message.publishedDateText())", "Collected \(message.publishedDateText())")
                        : L("发布于 \(message.publishedDateText())", "Published \(message.publishedDateText())")
                    Text(published + (message.expiresAt <= now ? L(" · 已结束展示", " · No longer displayed") : ""))
                        .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:8)
                    if message.sourceURL != nil {
                        Button { manager.openSource(for:message) } label: { Label(L("查看原文", "View source"),systemImage:"arrow.up.right") }
                            .buttonStyle(.link).font(.system(size:11))
                    }
                }
            }
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.primary.opacity(0.022),in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(Color.primary.opacity(0.12),lineWidth:0.6))
    }
}
