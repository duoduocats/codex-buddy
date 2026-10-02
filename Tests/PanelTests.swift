import AppKit

private final class FlippedContent: NSView {
    override var isFlipped: Bool { true }
}

@main struct PanelTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = NSViewController()
        controller.view = FlippedContent(frame:NSRect(x:0,y:0,width:380,height:825))
        let panel = QuotaPanel(maximumHeight:640)
        panel.contentViewController = controller
        panel.contentSize = NSSize(width:380,height:825)
        guard let scroll = controller.view.enclosingScrollView else { preconditionFailure("Native scroll surface missing") }
        precondition(panel.contentSize.height <= 640 && panel.contentSize.width == 380)
        precondition(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        precondition(controller.view.frame.height == 825,"Content must retain its full height")
        scroll.superview?.superview?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to:NSPoint(x:0,y:185))
        scroll.reflectScrolledClipView(scroll.contentView)
        precondition(scroll.contentView.bounds.minY > 0,"Tall content must scroll to its footer")
        panel.contentSize = NSSize(width:380,height:400)
        precondition(panel.contentSize.height == 400 && !scroll.hasVerticalScroller)
        precondition(controller.view.frame.height == 400)
        precondition(!scroll.drawsBackground,"Scroll surface must preserve native material")
        print("Native panel bounds tests passed: short-screen cap, full content, footer scrolling and compact recovery")
    }
}
