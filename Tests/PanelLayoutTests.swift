import AppKit
import SwiftUI

private final class PanelPreferences: UserDefaults {
    var values: [String:Any] = [:]
    override func object(forKey key:String) -> Any? { values[key] }
    override func bool(forKey key:String) -> Bool { values[key] as? Bool ?? false }
    override func data(forKey key:String) -> Data? { values[key] as? Data }
    override func set(_ value:Any?,forKey key:String) { values[key] = value }
    override func removeObject(forKey key:String) { values.removeValue(forKey:key) }
}

@main struct PanelLayoutTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let preferences = PanelPreferences()
        let model = AppModel(preferences:preferences,
            client:UsageClient(credentialProvider:{ fatalError("UI fixtures never read credentials") }))
        model.useDemo()
        let panel = QuotaPanel(maximumHeight:580)
        let hosting = NSHostingController(rootView:UsageView(model:model,settings:{},
            contentHeightChanged:{ panel.setContentHeight($0) }))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        let anchor = NSWindow(contentRect:NSRect(x:100,y:NSScreen.main!.visibleFrame.maxY+1,width:34,height:24),
            styleMask:[.borderless],backing:.buffered,defer:false)
        anchor.isReleasedWhenClosed = false
        let button = NSButton(frame:NSRect(x:0,y:0,width:34,height:24))
        anchor.contentView = button;anchor.orderFront(nil)
        panel.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        defer { panel.close();anchor.close() }
        func verify(_ label:String) async throws {
            try await Task.sleep(nanoseconds:250_000_000)
            let expected = ceil(hosting.sizeThatFits(in:NSSize(width:380,height:1600)).height)
            let scroll = hosting.view.enclosingScrollView!
            precondition(abs(hosting.view.frame.height-expected) <= 1,"\(label): document must match content, without blank footer")
            precondition(abs(panel.contentSize.height-min(expected,580)) <= 1,"\(label): panel must follow actual content")
            precondition(scroll.contentView.bounds.minY == 0,"\(label): content must start at the top")
        }
        try await verify("initial messages")
        let scroll = hosting.view.enclosingScrollView!
        scroll.contentView.scroll(to:NSPoint(x:0,y:75));scroll.reflectScrolledClipView(scroll.contentView)
        model.reminders.setMessagesEnabled(false)
        try await verify("messages disabled after scrolling")
        model.showDailyTokenUsage = false
        try await verify("chart hidden")
        model.showDailyTokenUsage = true
        try await verify("chart restored")
        model.reminders.setMessagesEnabled(true)
        try await verify("messages restored")
        model.now = model.now.addingTimeInterval(3*86_400)
        try await verify("messages expired")
        model.refreshing = true
        try await verify("quota refresh without layout change")
        print("Native panel layout checks passed: initial size, scroll recovery, messages off/on, chart off/on, expiry and refresh")
    }
}
