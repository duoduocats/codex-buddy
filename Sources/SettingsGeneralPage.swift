import AppKit
import SwiftUI

struct SettingsGeneralPage: View {
    @ObservedObject var reminders: ResetReminderManager
    @ObservedObject var login: LoginModel
    let updates: UpdateManager
    let pets: BuddyPetsController
    private let network:BuddyNetworkSettings
    private let tags:PetTagStore
    private let sample:Bool
    @StateObject private var storage = ApplicationStorageModel()
    init(reminders: ResetReminderManager,login: LoginModel,updates: UpdateManager,pets: BuddyPetsController,storage: ApplicationStorageModel? = nil,sample:Bool = false) {
        self.sample=sample;self.reminders=reminders;self.login=login;self.updates=updates;self.pets=pets
        if sample {
            let prefs=UsagePreviewPreferences();network=BuddyNetworkSettings(preferences:prefs,now:Date(timeIntervalSince1970:1791849600))
            network.record(.tags,bytes:1_200_000,complete:true);network.record(.preview,bytes:53_000_000,complete:true);network.record(.petPackage,bytes:140_000_000,complete:true)
            tags=PetTagStore(preferences:prefs,client:PetTagPreviewClient())
            tags.usePreview(.init(schemaVersion:1,revision:1,facets:[]),rows:[:])
        } else { network = .shared;tags = .shared }
        _storage=StateObject(wrappedValue:storage ?? ApplicationStorageModel())
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    if geometry.size.width >= 790 {
                        HStack(alignment:.top,spacing:20) {
                            GeneralDashboardPreferences(reminders:reminders,login:login,minimumHeight:310)
                                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                            GeneralDashboardUpdates(updates:updates,minimumHeight:310)
                                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                        }.fixedSize(horizontal:false,vertical:true)
                        HStack(alignment:.top,spacing:20) {
                            GeneralAlignedStorageView(storage:storage,pets:pets,updates:updates,minimumHeight:490)
                                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                            BuddyNetworkSettingsView(settings:network,tags:tags,sample:sample,compact:true,minimumHeight:490)
                                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                        }.fixedSize(horizontal:false,vertical:true)
                    } else {
                        GeneralDashboardPreferences(reminders:reminders,login:login)
                        GeneralDashboardUpdates(updates:updates)
                        GeneralAlignedStorageView(storage:storage,pets:pets,updates:updates)
                        BuddyNetworkSettingsView(settings:network,tags:tags,sample:sample,compact:true)
                    }
                }.fixedSize(horizontal:false,vertical:true)
                    .padding(.horizontal,28).padding(.vertical,24)
                    .frame(maxWidth:.infinity,minHeight:geometry.size.height,alignment:.center)
            }
        }.onAppear {login.refresh();storage.refresh()}
    }
}

private struct GeneralDashboardUpdates:View {
    @ObservedObject var updates:UpdateManager
    var minimumHeight:CGFloat = 0
    var body:some View {
        GeneralAlignedSection(L("更新", "Updates"),symbol:"arrow.triangle.2.circlepath",minimumHeight:minimumHeight) {
            VStack(alignment:.leading,spacing:12) {
                HStack(spacing:12) {
                    Text(updates.currentVersion).font(.system(size:20,weight:.medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityLabel(L("当前版本：", "Installed version: ")+updates.currentVersion)
                    Spacer(minLength:8)
                    Button {updates.check(manual:true)} label:{
                        Label(updates.checking ? L("检查中…", "Checking…") : L("检查更新", "Check for updates"),systemImage:"arrow.clockwise")
                            .font(.system(size:13,weight:.medium)).padding(.vertical,4).fixedSize()
                    }.buttonStyle(.bordered).disabled(updates.checking || updates.installing)
                }.frame(minHeight:72)
                Divider()
                GeneralAlignedPreferenceRow(title:L("接收 Beta 更新", "Receive Beta updates"),detail:L("包含正式版与测试版。", "Include stable and Beta releases."),selection:Binding(get:{updates.includesBeta},set:{updates.setIncludesBeta($0)}))
                    .frame(minHeight:72).disabled(updates.installing)
                if let release=updates.available {
                    VStack(alignment:.leading,spacing:10) {
                        Label(L("可更新至 \(release.tagName)", "Update available: \(release.tagName)"),systemImage:"arrow.down.circle")
                            .font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                        HStack(spacing:12) {
                            Button(L("更新说明", "Release notes")) {updates.openRelease()}.buttonStyle(.link)
                            Spacer(minLength:0)
                            Button(updates.installing ? L("更新中…", "Updating…") : updates.installFailed ? L("重试更新", "Retry update") : L("下载更新", "Download update")) {updates.installAvailable()}
                                .buttonStyle(.borderedProminent).disabled(updates.installing)
                        }
                    }.padding(14).background(Color.accentColor.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
                }
                Spacer(minLength:0)
                if let checked=updates.lastSuccessfulCheckAt {
                    Divider()
                    Text(L("最近检查 ", "Last checked ")+checked.formatted(date:.abbreviated,time:.shortened))
                        .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if let detail=updates.detailMessage {
                    Text(detail).font(.system(size:11)).foregroundStyle(updates.installFailed ? Color.red : Color.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                }
                if let retry=updates.nextRetryAt {
                    Text(L("下次重试 ", "Next retry ")+retry.formatted(date:.abbreviated,time:.shortened))
                        .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
        }
    }
}
private struct GeneralDashboardPreferences:View {
    @ObservedObject var reminders:ResetReminderManager
    @ObservedObject var login:LoginModel
    var minimumHeight:CGFloat = 0
    var body:some View {
        GeneralAlignedSection(L("应用偏好", "Preferences"),symbol:"slider.horizontal.3",minimumHeight:minimumHeight) {
            VStack(alignment:.leading,spacing:12) {
                GeneralAlignedPreferenceRow(title:L("开机启动", "Launch at login"),detail:L("登录 Mac 后自动打开。", "Open when you log into your Mac."),selection:Binding(get:{login.enabled},set:{login.set($0)})).frame(minHeight:72).disabled(login.updating)
                if let message=login.message {Text(message).font(.system(size:11)).foregroundStyle(.secondary)}
                if login.requiresApproval {Button(L("打开系统登录项", "Open Login Items")) {login.openSettings()}.buttonStyle(.link)}
                Divider()
                GeneralAlignedPreferenceRow(title:L("系统提醒", "System alerts"),detail:reminders.acceptsAnyMessages ? L("推送所选消息类型。", "Notify for selected message types.") : L("开启消息通知后可用。", "Enable messages first."),selection:Binding(get:{reminders.acceptsAnyMessages && reminders.enabled},set:{reminders.setEnabled($0)})).frame(minHeight:72).disabled(!reminders.acceptsAnyMessages)
                if let message=reminders.message {Text(message).font(.system(size:11)).foregroundStyle(.secondary)}
                Spacer(minLength:0)
            }
        }
    }
}
