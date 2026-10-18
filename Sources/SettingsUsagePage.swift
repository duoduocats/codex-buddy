import AppKit
import SwiftUI
import Combine

@MainActor struct SettingsUsagePage: View {
    let model: AppModel
    let preview: UsagePreviewModel
    let previewHighlight: UsagePreviewHighlight
    var previewFramesChanged: ([UsagePreviewAnchor: CGRect]) -> Void = { _ in }
    @ObservedObject var navigation: UsageNavigationState
    private let trendInteraction: UsageTrendInteraction?
    @StateObject private var trends: UsageTrendsPresentation
    @StateObject private var forecast: UsageForecastPresentation
    @StateObject private var clock: UsageHeaderClock
    init(model: AppModel,preview: UsagePreviewModel,previewHighlight: UsagePreviewHighlight,
         previewFramesChanged: @escaping ([UsagePreviewAnchor: CGRect]) -> Void = { _ in },
         navigation: UsageNavigationState,trendInteraction: UsageTrendInteraction? = nil) {
        self.model=model;self.preview=preview;self.previewHighlight=previewHighlight
        self.previewFramesChanged=previewFramesChanged;self.navigation=navigation;self.trendInteraction=trendInteraction
        _trends=StateObject(wrappedValue:UsageTrendsPresentation(model:model))
        _forecast=StateObject(wrappedValue:UsageForecastPresentation(model:model))
        _clock=StateObject(wrappedValue:UsageHeaderClock(model:model))
    }
    private var page: UsageSubpage { navigation.page }
    var body: some View {
        VStack(spacing:0) {
            if page == .trends || page == .forecast {
                HStack(spacing:12) {
                    Spacer(minLength:0)
                    if trends.sample {
                        Text(L("模拟数据", "Sample data")).font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal,9).padding(.vertical,4).background(Color.primary.opacity(0.06),in:Capsule()).fixedSize()
                    }
                    Text(clock.timestamp).font(.system(size:13)).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8).accessibilityIdentifier("usage-current-time")
                }.padding(.horizontal,28).padding(.top,12).padding(.bottom,8)
            }
            UsageSubpagesHost(page:page) { item in
                switch item {
                case .display:
                    return AnyView(SettingsOverviewPage(model:model,preview:preview,previewHighlight:previewHighlight,
                        previewFramesChanged:previewFramesChanged))
                case .trends: return AnyView(UsageTrendsPage(state:trends,interaction:trendInteraction))
                case .forecast: return AnyView(UsageForecastPage(state:forecast))
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            BuddyBottomNavigation(items:UsageSubpage.allCases.map {
                BuddyNavigationItem(id:$0.rawValue,title:$0.title,symbol:$0.symbol)
            },selection:Binding(get:{page.rawValue},set:{if let next=UsageSubpage(rawValue:$0) {navigation.page=next}}),
                accessibilityPrefix:"usage-tab-",accessibilityLabel:L("用量页面", "Usage pages"))
                .frame(width:510,height:60).padding(.top,8).padding(.bottom,14)
                .frame(maxWidth:.infinity)
        }
    }
}

private struct UsageSubpagesHost: NSViewRepresentable {
    var page: UsageSubpage
    var content: (UsageSubpage) -> AnyView
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSView { NSView() }
    func updateNSView(_ view:NSView,context:Context) { context.coordinator.show(page,in:view,content:content) }
    final class Coordinator {
        private var hosts: [UsageSubpage:NSHostingView<AnyView>] = [:]
        private var page: UsageSubpage?
        func show(_ next: UsageSubpage,in view: NSView,content: (UsageSubpage) -> AnyView) {
            guard next != page else { return }
            view.subviews.forEach { $0.removeFromSuperview() }
            let host: NSHostingView<AnyView>
            if let existing=hosts[next] { host=existing }
            else { host=NSHostingView(rootView:content(next));host.sizingOptions=[];host.autoresizingMask=[.width,.height];hosts[next]=host }
            host.frame=view.bounds;view.addSubview(host);page=next
        }
    }
}

// Minute-only header projection; clock ticks never rebuild annual usage data.
@MainActor private final class UsageHeaderClock: ObservableObject {
    @Published private(set) var date: Date
    private var key: String
    private var subscription: AnyCancellable?
    private let day=DateFormatter(),time=DateFormatter()
    init(model:AppModel) {
        date=model.now;key=Self.key(model.now)
        subscription=model.$now.sink { [weak self] value in
            guard let self else { return }
            let next=Self.key(value);guard next != self.key else { return }
            self.key=next;self.date=value
        }
    }
    private static func key(_ date:Date) -> String {
        String(Int(date.timeIntervalSince1970/60))+"|"+TimeZone.autoupdatingCurrent.identifier+"|"+Locale.autoupdatingCurrent.identifier
    }
    var timestamp:String {
        for value in [day,time] { value.locale = .autoupdatingCurrent;value.timeZone = .autoupdatingCurrent }
        day.setLocalizedDateFormatFromTemplate("yMMMd");time.setLocalizedDateFormatFromTemplate("HHmm")
        return day.string(from:date)+" "+time.string(from:date)
    }
}
