import SwiftUI
import AppKit

enum BuddyPage: String, CaseIterable, Identifiable {
    case overview, pets, messages, general
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: return L("用量", "Usage")
        case .pets: return L("宠物", "Pets")
        case .messages: return L("消息", "Messages")
        case .general: return L("通用", "General")
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "chart.bar.fill"
        case .pets: return "pawprint.fill"
        case .messages: return "bubble.left.and.bubble.right"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    static let width: CGFloat = 1240
    static let height: CGFloat = 1000
    static let minimumSize = NSSize(width:960,height:540)
    static func preferredHeight(for page: BuddyPage) -> CGFloat {
        switch page {
        case .overview: return height
        case .pets, .messages, .general: return height
        }
    }
    static func fittedHeight(for page: BuddyPage,availableHeight: CGFloat) -> CGFloat {
        min(preferredHeight(for:page),max(minimumSize.height,availableHeight-80))
    }
    let model: AppModel
    var openChallenge: () -> Void = {}
    @StateObject var login = LoginModel()
    var updates: UpdateManager = .shared
    var pets: BuddyPetsController = .shared
    var initialPage: BuddyPage = .overview
    var initialUsageSubpage: UsageSubpage = .display
    var trendInteraction: UsageTrendInteraction? = nil
    var previewFramesChanged: ([UsagePreviewAnchor: CGRect]) -> Void = { _ in }
    var pageChanged: (BuddyPage) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var preview = UsagePreviewModel()
    @StateObject private var usageNavigation = UsageNavigationState()
    @State private var selection: BuddyPage?
    @State private var previewHighlight = UsagePreviewHighlight()
    private var page: BuddyPage { selection ?? initialPage }

    var body: some View {
        HStack(spacing:0) {
            sidebar
            Rectangle().fill(colorScheme == .dark ? Color(red:40/255,green:43/255,blue:46/255) : Color.primary.opacity(0.12)).frame(width:1).accessibilityHidden(true)
            SettingsPagesHost(page:page) { item in
                switch item {
                case .overview: return AnyView(SettingsUsagePage(model:model,preview:preview,previewHighlight:previewHighlight,previewFramesChanged:previewFramesChanged,navigation:usageNavigation,trendInteraction:trendInteraction))
                case .pets: return AnyView(BuddyPetsPage(controller:pets,updates:updates))
                case .messages: return AnyView(SettingsMessagesPage(model:model))
                case .general: return AnyView(SettingsGeneralPage(reminders:model.reminders,login:login,updates:updates,pets:pets,sample:model.isDemonstrating))
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
                .background(colorScheme == .dark ? Color(red:24/255,green:26/255,blue:28/255) : Color(nsColor:.windowBackgroundColor))
        }.font(.system(size:13)).controlSize(.regular)
            .frame(minWidth:Self.minimumSize.width,idealWidth:Self.width,maxWidth:.infinity,
                   minHeight:Self.minimumSize.height,idealHeight:Self.height,maxHeight:.infinity)
            .onAppear { usageNavigation.configure(initialUsageSubpage);syncUsageVisibility();login.refresh();pets.setVisible(page == .pets) }
            .onDisappear { pets.setVisible(false) }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
            .onChange(of:page) { syncUsageVisibility();login.refresh();pets.setVisible($0 == .pets);pageChanged($0) }
            .onChange(of:usageNavigation.page) { _ in syncUsageVisibility() }
    }
    private func syncUsageVisibility() { model.setUsageTrendsVisible(page == .overview && usageNavigation.page == .trends) }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:10) {
                if let icon = BuddyBrand.settingsGlyph {
                    Image(nsImage:icon).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        .frame(width:42,height:42).accessibilityHidden(true)
                }
            }.frame(maxWidth:.infinity,alignment:.center).padding(.horizontal,16).padding(.top,40).padding(.bottom,32)
            VStack(spacing:5) {
                ForEach(BuddyPage.allCases) { item in
                    Button { if page != item { selection = item } } label: {
                        HStack(spacing:AppLanguage.chinese ? 18 : 10) {
                            Image(systemName:item.symbol).font(.system(size:18,weight:.medium)).frame(width:20).accessibilityHidden(true)
                            Text(item.title).lineLimit(1).minimumScaleFactor(0.8).fixedSize(horizontal:false,vertical:true)
                        }.font(.system(size:AppLanguage.chinese ? 16 : 14,weight:page == item ? .semibold : .medium))
                            .padding(.horizontal,14).padding(.vertical,14)
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .foregroundStyle(page == item ? Color.accentColor : Color.primary)
                            .background(page == item ? Color.accentColor.opacity(0.12) : Color.clear,in:RoundedRectangle(cornerRadius:8))
                            .contentShape(RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                        .accessibilityIdentifier("buddy-page-"+item.rawValue)
                }
            }.padding(.horizontal,9)
            Spacer(minLength:16)
        }.frame(width:142).frame(maxHeight:.infinity,alignment:.top)
            .background(colorScheme == .dark ? Color(red:31/255,green:34/255,blue:37/255) : Color(nsColor:.windowBackgroundColor))
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
