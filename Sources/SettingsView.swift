import SwiftUI
import AppKit

enum BuddyPage: String, CaseIterable, Identifiable {
    case overview, pets, messages, general
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: return L("用量概览", "Usage overview")
        case .pets: return L("宠物", "Pets")
        case .messages: return L("消息", "Messages")
        case .general: return L("通用", "General")
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "menubar.rectangle"
        case .pets: return "pawprint.fill"
        case .messages: return "bubble.left.and.bubble.right"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    static let width: CGFloat = 1240
    static let height: CGFloat = 1040
    static let minimumSize = NSSize(width:960,height:540)
    static func preferredHeight(for page: BuddyPage) -> CGFloat {
        switch page {
        case .overview: return height
        case .pets, .messages: return 900
        case .general: return 620
        }
    }
    static func fittedHeight(for page: BuddyPage,availableHeight: CGFloat) -> CGFloat {
        min(preferredHeight(for:page),max(minimumSize.height,availableHeight-80))
    }
    @ObservedObject var model: AppModel
    var openChallenge: () -> Void = {}
    @StateObject var login = LoginModel()
    @ObservedObject var updates: UpdateManager = .shared
    @ObservedObject var pets: BuddyPetsController = .shared
    var initialPage: BuddyPage = .overview
    var previewFramesChanged: ([UsagePreviewAnchor: CGRect]) -> Void = { _ in }
    var pageChanged: (BuddyPage) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var preview = UsagePreviewModel()
    @State private var selection: BuddyPage?
    @State private var previewHighlight = UsagePreviewHighlight()
    private var page: BuddyPage { selection ?? initialPage }

    var body: some View {
        HStack(spacing:0) {
            sidebar
            Divider()
            Group {
                switch page {
                case .overview: overview
                case .pets: BuddyPetsPage(controller:pets,updates:updates)
                case .messages: RecentMessagesView(manager:model.reminders,challenge:model.challenge,now:model.now)
                case .general: general
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
                .background(Color(nsColor:.windowBackgroundColor).overlay(Color.primary.opacity(0.018)))
        }.font(.system(size:13)).controlSize(.regular)
            .frame(minWidth:Self.minimumSize.width,idealWidth:Self.width,maxWidth:.infinity,
                   minHeight:Self.minimumSize.height,idealHeight:Self.height,maxHeight:.infinity)
            .onAppear { preview.apply(UsagePreviewStyle(model));pets.setVisible(page == .pets) }
            .onDisappear { pets.setVisible(false) }
            .onChange(of:UsagePreviewStyle(model)) { preview.apply($0) }
            .onChange(of:page) { pets.setVisible($0 == .pets);pageChanged($0) }
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:10) {
                if let icon = BuddyBrand.settingsGlyph {
                    Image(nsImage:icon).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        .frame(width:42,height:42).accessibilityHidden(true)
                }
            }.frame(maxWidth:.infinity,alignment:.center).padding(.horizontal,16).padding(.top,40).padding(.bottom,36)
            VStack(spacing:7) {
                ForEach(BuddyPage.allCases) { item in
                    Button { selection = item } label: {
                        HStack(spacing:10) {
                            Image(systemName:item.symbol).frame(width:20).accessibilityHidden(true)
                            Text(item.title).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                        }.font(.system(size:13,weight:page == item ? .semibold : .medium))
                            .padding(.horizontal,10).padding(.vertical,11)
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .foregroundStyle(page == item ? Color.accentColor : Color.primary)
                            .background(page == item ? Color.accentColor.opacity(0.12) : Color.clear,in:RoundedRectangle(cornerRadius:8))
                            .contentShape(RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                        .accessibilityIdentifier("buddy-page-"+item.rawValue)
                }
            }.padding(.horizontal,10)
            Spacer(minLength:16)
        }.frame(width:148).frame(maxHeight:.infinity,alignment:.top).background(SettingsSidebarMaterial())
    }
    private var overview: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:32) {
                    HStack(alignment:.bottom) {
                        BuddyPageHeading(title:BuddyPage.overview.title)
                        Spacer(minLength:20)
                    }
                    Group {
                        if geometry.size.width >= 1066 {
                            HStack(alignment:.top,spacing:30) {
                                menuControls.frame(width:270).padding(.top,8)
                                previewColumn
                                panelControls.frame(width:300).padding(.top,8)
                            }
                        } else {
                            HStack(alignment:.top,spacing:36) {
                                VStack(spacing:22) { menuControls;panelControls }.frame(width:270)
                                previewColumn
                            }
                        }
                    }.frame(maxWidth:.infinity,minHeight:max(0,geometry.size.height-160),alignment:.center)
                        .environment(\.usagePreviewEnabled,true)
                        .overlayPreferenceValue(UsagePreviewAnchors.self) { anchors in
                            GeometryReader { proxy in
                                UsagePreviewLines(frames:anchors.mapValues { proxy[$0] },highlight:previewHighlight,framesChanged:previewFramesChanged)
                            }
                        }
                }.padding(28).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
    private var previewColumn: some View {
        VStack(spacing:16) {
            Text(L("模拟数据预览", "Sample data preview")).font(.system(size:12)).foregroundStyle(.secondary)
                .frame(maxWidth:.infinity,alignment:.leading)
            UsagePreviewCanvas(model:preview.model,updates:preview.updates)
        }.frame(width:380)
    }
    private var menuControls: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("顶栏", "Menu bar")).font(.system(size:18,weight:.semibold))
            control(.theme) {
                VStack(alignment:.leading,spacing:18) {
                    Text(L("顶栏主题", "Menu bar theme")).font(.system(size:14,weight:.semibold))
                    HStack(spacing:4) {
                        ForEach(MenuBarTheme.allCases) { theme in
                            Button { model.menuBarTheme = theme } label: {
                                VStack(spacing:8) {
                                    Image(nsImage:DuoDrawing.image(size:NSSize(width:32,height:26),
                                        window:LimitWindow(usedPercent:0,windowDurationMins:nil,resetsAt:nil),
                                        credits:4,now:preview.model.now,menu:true,dark:model.menuBarTheme == theme || colorScheme == .dark,
                                        menuTheme:theme,showsLabel:false)).frame(width:32,height:26).accessibilityHidden(true)
                                    Text(theme.title).font(.system(size:13,weight:.medium))
                                }.frame(maxWidth:.infinity).frame(height:72)
                                    .foregroundStyle(model.menuBarTheme == theme ? Color.white : Color.primary)
                                    .background(model.menuBarTheme == theme ? Color.blue : Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:8))
                                    .overlay(RoundedRectangle(cornerRadius:8).stroke(model.menuBarTheme == theme ? Color.blue.opacity(0.9) : .clear,lineWidth:1))
                                    .contentShape(RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).accessibilityLabel(theme.title)
                                .accessibilityAddTraits(model.menuBarTheme == theme ? .isSelected : [])
                        }
                    }
                    HStack(spacing:12) {
                        ForEach(MenuBarTheme.allCases) { theme in
                            VStack(spacing:9) {
                                Image(nsImage:DuoDrawing.image(size:NSSize(width:64,height:52),
                                    window:LimitWindow(usedPercent:32,windowDurationMins:10080,resetsAt:preview.model.now.addingTimeInterval(4*86_400).timeIntervalSince1970),
                                    credits:3,now:preview.model.now,menu:true,dark:colorScheme == .dark,menuTheme:theme))
                                    .frame(width:64,height:52).accessibilityHidden(true)
                                Text(theme == .ring ? "Ring" : "DuoDuoCat").font(.system(size:11))
                            }.frame(maxWidth:.infinity)
                        }
                    }.padding(.vertical,8)
                }
            }
            control(.display) {
                VStack(alignment:.leading,spacing:16) {
                    Text(L("显示内容", "Display")).font(.system(size:14,weight:.semibold))
                    SettingsSegments(labels:[L("时间", "Time"),L("百分比", "Percentage")],selection:Binding(
                        get:{model.menuShowsPercentage ? 1 : 0},set:{model.menuShowsPercentage = $0 == 1}),
                        accessibilityLabel:L("显示内容", "Display")).frame(height:30)
                }
            }
        }.padding(16).background(Color.primary.opacity(0.02),in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(Color.primary.opacity(0.09),lineWidth:0.7))
    }
    private var panelControls: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("展开面板", "Panel")).font(.system(size:18,weight:.semibold))
            control(.messages) {
                VStack(spacing:14) {
                    overviewToggle(L("消息通知", "Messages"),selection:Binding(
                        get:{model.reminders.messagesEnabled},set:{model.reminders.setMessagesEnabled($0)}))
                    Divider()
                    VStack(spacing:12) {
                        overviewToggle(L("重置提醒", "Reset reminders"),selection:Binding(
                            get:{model.reminders.resetMessagesEnabled},set:{model.reminders.setResetMessagesEnabled($0)}))
                        overviewToggle(L("活动消息", "Activity messages"),selection:Binding(
                            get:{model.reminders.activityMessagesEnabled},set:{model.reminders.setActivityMessagesEnabled($0)}))
                    }.padding(.leading,14).disabled(!model.reminders.messagesEnabled)
                }
            }
            control(.resets) {
                VStack(alignment:.leading,spacing:16) {
                    overviewToggle(L("重置明细", "Reset details"),selection:$model.showResetDetails)
                    Divider()
                    Text(L("显示范围", "Show")).font(.system(size:12)).foregroundStyle(.secondary)
                    SettingsSegments(labels:[L("全部", "All"),L("最近到期", "Upcoming")],selection:Binding(
                        get:{model.resetDetailsOnlySoonest ? 1 : 0},set:{model.resetDetailsOnlySoonest = $0 == 1}),
                        accessibilityLabel:L("重置明细展示范围", "Reset detail range")).frame(height:30).disabled(!model.showResetDetails)
                    if model.resetDetailsOnlySoonest && model.showResetDetails {
                        Picker(L("到期范围", "Expiry window"),selection:$model.resetExpiryWindowDays) {
                            ForEach([1,3,7,14,30],id:\.self) { days in Text(L("未来 \(days) 天", "Next \(days) days")).tag(days) }
                        }.pickerStyle(.menu)
                    }
                }
            }
            control(.chart) { overviewToggle(L("每日 Token 用量", "Daily token usage"),selection:$model.showDailyTokenUsage) }
            control(.sharing) { overviewToggle(L("分享按钮", "Sharing button"),selection:$model.showUsageShareButton).disabled(!model.showDailyTokenUsage) }
        }.padding(16).background(Color.primary.opacity(0.02),in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(Color.primary.opacity(0.09),lineWidth:0.7))
    }
    private func overviewToggle(_ title: String,selection: Binding<Bool>) -> some View {
        HStack(spacing:12) {
            Text(title).font(.system(size:14,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                .frame(maxWidth:.infinity,alignment:.leading)
            Toggle(title,isOn:selection).labelsHidden().toggleStyle(OverviewSwitchStyle(title:title))
        }.frame(minHeight:32)
    }
    private func control<Content: View>(_ part: UsagePreviewPart,@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth:.infinity,alignment:.leading).padding(14)
            .background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.085),lineWidth:0.6))
            .usagePreviewAnchor(.control(part)).onHover { previewHighlight.setHovered($0 ? part : nil) }
    }
    private var general: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:28) {
                    BuddyPageHeading(title:BuddyPage.general.title)
                    HStack(alignment:.top,spacing:24) {
                        generalGroup(L("版本更新", "Updates"),symbol:"arrow.triangle.2.circlepath") {
                            GeneralUpdatesView(updates:updates)
                        }.frame(width:max(0,(geometry.size.width-88)*0.56))
                        VStack(spacing:20) {
                            generalGroup(L("启动", "Startup"),symbol:"power") {
                                GeneralPreferenceRow(title:L("开机启动", "Launch at login"),
                                    detail:L("登录 Mac 后自动打开。", "Open Codex Buddy when you log in."),
                                    selection:Binding(get:{login.enabled},set:{login.set($0)}))
                                if let message = login.message {
                                    Text(message).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                }
                            }
                            generalGroup(L("通知", "Notifications"),symbol:"bell") {
                                GeneralPreferenceRow(title:L("系统提醒", "System alerts"),
                                    detail:model.reminders.acceptsAnyMessages
                                        ? L("按消息类型设置推送到通知中心。", "Send the selected message types to Notification Center.")
                                        : L("开启消息通知并选择消息类型后可用。", "Enable messages and select a type first."),
                                    selection:Binding(get:{model.reminders.acceptsAnyMessages && model.reminders.enabled},
                                        set:{model.reminders.setEnabled($0)})).disabled(!model.reminders.acceptsAnyMessages)
                                if let message = model.reminders.message {
                                    Text(message).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                }
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }.padding(32).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
    private func generalGroup<Content: View>(_ title: String,symbol: String,@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(spacing:12) {
                Image(systemName:symbol).font(.system(size:26,weight:.regular)).foregroundStyle(Color.blue).frame(width:32).accessibilityHidden(true)
                Text(title).font(.system(size:20,weight:.semibold)).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment:.leading,spacing:12) { content() }
                .padding(20).frame(maxWidth:.infinity,alignment:.leading)
                .background(Color.primary.opacity(0.02),in:RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.08),lineWidth:0.6))
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.primary.opacity(0.018),in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(Color.primary.opacity(0.10),lineWidth:0.7))
    }
}
struct BuddyPageHeading: View {
    let title: String
    var detail: String = ""
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.system(size:32,weight:.bold)).accessibilityAddTraits(.isHeader)
            if !detail.isEmpty {
                Text(detail).font(.system(size:13)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
}
struct SettingsGroup<Content:View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment:.leading,spacing:0) { content }.padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading) }
}
struct SettingsToggleRow: View {
    var title: String
    var detail: String
    var selection: Binding<Bool>
    var compact = false
    var body: some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:5) {
                Text(title).font(.system(size:compact ? 12 : 13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                if !compact { Text(detail).font(.system(size:11)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal:false,vertical:true) }
            }.frame(maxWidth:.infinity,alignment:.leading)
            Toggle(title,isOn:selection).labelsHidden().toggleStyle(.switch).controlSize(compact ? .small : .regular).accessibilityHint(detail).help(detail)
        }.frame(minHeight:compact ? 30 : 44)
    }
}
private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context:Context) -> NSVisualEffectView {
        let view = NSVisualEffectView();view.material = .sidebar;view.blendingMode = .behindWindow;view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {}
}
struct SettingsSegments: View {
    var labels: [String]
    @Binding var selection: Int
    var accessibilityLabel: String
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing:2) {
            ForEach(labels.indices,id:\.self) { index in
                Button { selection = index } label: {
                    Text(labels[index]).font(.system(size:12,weight:.medium))
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                        .foregroundStyle(enabled && selection == index ? Color.white : Color.primary.opacity(enabled ? 1 : 0.35))
                        .background(selection == index ? (enabled ? Color.blue : Color.primary.opacity(0.08)) : .clear,in:RoundedRectangle(cornerRadius:6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }.padding(2).background(Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:8))
            .accessibilityElement(children:.contain).accessibilityLabel(accessibilityLabel)
    }
}
