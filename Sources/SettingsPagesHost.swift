import AppKit
import SwiftUI

struct SettingsMessagesPage: View {
    @ObservedObject var model: AppModel
    var body: some View { RecentMessagesView(manager:model.reminders,challenge:model.challenge,now:model.now) }
}

// Retain each page's search, selection and scroll state. Only the visible native
// host participates in layout; quota ticks cannot rebuild the whole navigation.
struct SettingsPagesHost: NSViewRepresentable {
    var page: BuddyPage
    var content: (BuddyPage) -> AnyView
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView,context: Context) {
        context.coordinator.show(page,in:container,content:content)
    }
    final class Coordinator {
        private var hosts: [BuddyPage:NSHostingView<AnyView>] = [:]
        private(set) var page: BuddyPage?
        func show(_ next: BuddyPage,in container: NSView,content: (BuddyPage) -> AnyView) {
            guard next != page else { return }
            container.subviews.forEach { $0.removeFromSuperview() }
            let host: NSHostingView<AnyView>
            if let existing = hosts[next] { host = existing }
            else {
                host = NSHostingView(rootView:AnyView(content(next).font(.system(size:13)).controlSize(.regular)));host.sizingOptions = []
                host.autoresizingMask = [.width,.height];hosts[next] = host
            }
            host.frame = container.bounds;container.addSubview(host);page = next
        }
    }
}
