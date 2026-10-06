import SwiftUI
import AppKit

private enum SettingsAnchor: String, CaseIterable, Identifiable {
    case menuBar, panel, messages, general
    var id: Self { self }
    var title: String {
        switch self {
        case .menuBar: return L("顶栏显示", "Menu bar")
        case .panel: return L("展开面板", "Panel")
        case .messages: return L("系统提醒", "System alerts")
        case .general: return L("通用与更新", "General & updates")
        }
    }
    var symbol: String {
        switch self {
        case .menuBar: return "menubar.rectangle"
        case .panel: return "rectangle.topthird.inset.filled"
        case .messages: return "bell.badge"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    static let width: CGFloat = 780
    static let height: CGFloat = 640
    static let minimumSize = NSSize(width:700,height:480)
    @ObservedObject var model: AppModel
    var openChallenge: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @StateObject var login = LoginModel()
    @ObservedObject var updates: UpdateManager = .shared
    @State private var selectedAnchor: SettingsAnchor = .menuBar
    @State private var scrollRequest = 0

    var body: some View {
        HStack(spacing:0) {
            sidebar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment:.leading,spacing:32) {
                        Text(L("设置", "Settings"))
                            .font(.system(size:24,weight:.bold))
                            .padding(.bottom,4)
                        section(.menuBar) { menuBarSettings }
                        section(.panel) { panelSettings }
                        section(.messages) { SystemReminderSettings(manager:model.reminders) }
                        section(.general) { generalSettings }
                    }.frame(maxWidth:600,alignment:.leading).padding(.horizontal,28).padding(.vertical,24)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }.background(Color(nsColor:.windowBackgroundColor).overlay(Color.primary.opacity(0.025)))
                    .onChange(of:scrollRequest) { _ in
                        withAnimation(.easeInOut(duration:0.22)) {
                            proxy.scrollTo(selectedAnchor,anchor:.top)
                        }
                    }
            }
        }.font(.system(size:13)).controlSize(.regular)
            .frame(minWidth:Self.minimumSize.width,idealWidth:Self.width,maxWidth:.infinity,
                   minHeight:Self.minimumSize.height,idealHeight:Self.height,maxHeight:.infinity)
    }

    private var sidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                if let icon = BuddyBrand.settingsGlyph {
                    Image(nsImage:icon).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        .frame(width:32,height:32).accessibilityHidden(true)
                }
                Text("Codex Buddy").font(.system(size:15,weight:.bold))
            }.padding(.horizontal,16).padding(.top,14).padding(.bottom,14)
            VStack(spacing:3) {
                ForEach(SettingsAnchor.allCases) { anchor in
                    Button {
                        selectedAnchor = anchor
                        scrollRequest += 1
                    } label: {
                        HStack(spacing:10) {
                            Image(systemName:anchor.symbol).frame(width:20).accessibilityHidden(true)
                            Text(anchor.title).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                        }.font(.system(size:13,weight:.medium))
                            .padding(.horizontal,10).padding(.vertical,8)
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .foregroundStyle(Color.primary)
                            .background(selectedAnchor == anchor ? Color.accentColor.opacity(0.13) : Color.clear,
                                        in:RoundedRectangle(cornerRadius:7))
                            .contentShape(RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selectedAnchor == anchor ? .isSelected : [])
                        .accessibilityLabel(anchor.title)
                        .help(L("滚动到\(anchor.title)", "Scroll to \(anchor.title)"))
                }
            }.padding(.horizontal,12)
            Spacer(minLength:16)
        }.frame(width:196).frame(maxHeight:.infinity,alignment:.top)
            .background(SettingsSidebarMaterial())
    }

    private func section<Content:View>(_ anchor:SettingsAnchor,@ViewBuilder content:() -> Content) -> some View {
        VStack(alignment:.leading,spacing:16) {
            Text(anchor.title).font(.system(size:16,weight:.bold))
                .accessibilityAddTraits(.isHeader)
            content()
        }.id(anchor).frame(maxWidth:.infinity,alignment:.leading)
    }

    private var menuBarSettings: some View {
        SettingsGroup {
            HStack(spacing:16) {
                Text(L("顶栏主题", "Theme"))
                Spacer(minLength:12)
                SettingsSegments(labels:MenuBarTheme.allCases.map(\.title),selection:Binding(
                    get:{model.menuBarTheme == .ring ? 0 : 1},
                    set:{model.menuBarTheme = $0 == 0 ? .ring : .duoDuoCat}),
                    accessibilityLabel:L("顶栏主题", "Theme"))
                    .frame(width:184,height:24)
            }.frame(minHeight:34)
            Spacer().frame(height:12)
            HStack(spacing:16) {
                Text(L("显示内容", "Display"))
                Spacer(minLength:12)
                SettingsSegments(labels:[L("时间", "Time"),L("百分比", "Percentage")],selection:Binding(
                    get:{model.menuShowsPercentage ? 1 : 0},
                    set:{model.menuShowsPercentage = $0 == 1}),
                    accessibilityLabel:L("显示内容", "Display"))
                    .frame(width:184,height:24)
            }.frame(minHeight:34)
        }
    }

    private var panelSettings: some View {
        VStack(alignment:.leading,spacing:24) {
            PanelMessageSettings(manager:model.reminders)
            VStack(alignment:.leading,spacing:12) {
                SettingsToggleRow(title:L("重置明细", "Reset details"),
                    detail:L("查看可用重置的到期时间。", "See when your available resets expire."),
                    selection:$model.showResetDetails)
                HStack(spacing:16) {
                    Text(L("显示范围", "Show")).font(.system(size:12,weight:.medium))
                    Spacer(minLength:12)
                    SettingsSegments(labels:[L("全部", "All"),L("最近到期", "Upcoming")],selection:Binding(
                        get:{model.resetDetailsOnlySoonest ? 1 : 0},set:{model.resetDetailsOnlySoonest = $0 == 1}),
                        accessibilityLabel:L("重置明细展示范围", "Reset detail range"))
                        .frame(width:184,height:24)
                }.padding(.leading,16).disabled(!model.showResetDetails)
                if model.resetDetailsOnlySoonest {
                    HStack(spacing:16) {
                        Text(L("到期范围", "Expiry window")).font(.system(size:12,weight:.medium))
                        Spacer(minLength:12)
                        Picker(L("到期范围", "Expiry window"),selection:$model.resetExpiryWindowDays) {
                            ForEach([1,3,7,14,30],id:\.self) { days in Text(L("未来 \(days) 天", "Next \(days) days")).tag(days) }
                        }.labelsHidden().pickerStyle(.menu).frame(width:184,alignment:.trailing)
                    }.padding(.leading,16).disabled(!model.showResetDetails)
                }
            }
            VStack(alignment:.leading,spacing:12) {
                SettingsToggleRow(title:L("每日 Token 用量", "Daily token usage"),
                    detail:L("显示每日曲线和累计统计。", "Show the daily chart and usage statistics."),
                    selection:$model.showDailyTokenUsage)
                SettingsToggleRow(title:L("分享按钮", "Sharing button"),
                    detail:model.showDailyTokenUsage
                        ? L("分享、保存或复制用量图片。", "Share, save, or copy your usage image.")
                        : L("开启每日 Token 用量后可使用。", "Enable daily token usage to share images."),
                    selection:$model.showUsageShareButton,compact:true)
                    .disabled(!model.showDailyTokenUsage).padding(.leading,16)
            }
        }
    }

    private var generalSettings: some View {
        SettingsGroup {
            SettingsToggleRow(title:L("开机启动", "Launch at login"),
                detail:L("登录 Mac 后自动打开。", "Open Codex Buddy when you log in."),
                selection:Binding(get:{login.enabled},set:{login.set($0)}))
            if let message = login.message {
                Text(message).font(.system(size:11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true).padding(.top,10)
            }
            SettingsUpdateSection(updates:updates).padding(.top,20)
            TiboChallengeSettingsEntry(manager:model.challenge,now:model.now,open:openChallenge).padding(.top,20)
        }
    }

}

struct SettingsGroup<Content:View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment:.leading,spacing:0) { content }
            .padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct SettingsToggleRow: View {
    var title: String
    var detail: String
    var selection: Binding<Bool>
    var compact = false
    var body: some View {
        HStack(spacing:20) {
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(.system(size:compact ? 12 : 13,weight:.medium))
                if !compact {
                    Text(detail).font(.system(size:11)).foregroundStyle(.secondary).lineSpacing(2)
                        .fixedSize(horizontal:false,vertical:true)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
            Toggle(title,isOn:selection).labelsHidden().toggleStyle(.switch).controlSize(compact ? .small : .regular)
                .accessibilityHint(detail).help(detail)
        }.frame(minHeight:compact ? 30 : 44)
    }
}

private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context:Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar;view.blendingMode = .behindWindow;view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {}
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
        for index in labels.indices { control.setWidth(184 / CGFloat(labels.count),forSegment:index) }
        control.font = .systemFont(ofSize:13)
        control.setAccessibilityLabel(accessibilityLabel)
        return control
    }
    func updateNSView(_ control:NSSegmentedControl,context:Context) {
        context.coordinator.parent = self
        control.selectedSegment = selection
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSSegmentedControl,context:Context) -> CGSize? {
        CGSize(width:184,height:24)
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
