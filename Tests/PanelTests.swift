import AppKit

private final class FlippedContent: NSView {
    override var isFlipped: Bool { true }
}

@main struct PanelTests {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.activate(ignoringOtherApps:true)
        let controller = NSViewController()
        controller.view = FlippedContent(frame:NSRect(x:0,y:0,width:380,height:825))
        let panel = QuotaPanel(maximumHeight:640,reduceMotion:{false})
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
        precondition(scroll.contentView.bounds.minY == 0,"Collapsed content must return to its top")
        panel.contentSize = NSSize(width:380,height:700)
        scroll.contentView.scroll(to:NSPoint(x:0,y:60))
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.contentSize = NSSize(width:380,height:680)
        precondition(scroll.contentView.bounds.minY == 0,"Expiry at the screen cap must clear stale scroll offsets")
        panel.contentSize = NSSize(width:380,height:400)
        precondition(!scroll.drawsBackground,"Scroll surface must preserve native material")
        let anchor=NSWindow(contentRect:NSRect(x:100,y:NSScreen.main!.visibleFrame.maxY+1,width:34,height:24),
            styleMask:[.borderless],backing:.buffered,defer:false)
        anchor.isReleasedWhenClosed=false
        let button=NSButton(frame:NSRect(x:0,y:0,width:34,height:24));anchor.contentView=button;anchor.orderFront(nil)
        panel.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        defer { panel.close();anchor.close() }
        // Match native launch before asking WindowServer to animate a newly shown panel.
        try await Task.sleep(nanoseconds:200_000_000)
        let nativeWindow=controller.view.window!, top=nativeWindow.frame.maxY
        var frames: [NSRect] = []
        let observer = NotificationCenter.default.addObserver(forName:NSWindow.didResizeNotification,
            object:nativeWindow,queue:.main) { _ in
            MainActor.assumeIsolated { frames.append(nativeWindow.frame) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        panel.prepareForMessageTransition(animated:true)
        panel.contentSize=NSSize(width:380,height:600)
        try await Task.sleep(nanoseconds:350_000_000)
        fputs("Animated frame heights: \(frames.map { $0.height })\n",stderr)
        precondition(frames.contains { $0.height > 400 && $0.height < 600 },"A message resize must pass through intermediate heights")
        precondition(frames.allSatisfy { abs($0.maxY-top) < 1 },"Every animation frame must preserve the menu-bar top anchor")
        precondition(nativeWindow.frame.height == 600 && scroll.contentView.bounds.minY == 0)
        panel.prepareForMessageTransition(animated:true);panel.contentSize=NSSize(width:380,height:400)
        try await Task.sleep(nanoseconds:50_000_000)
        panel.prepareForMessageTransition(animated:true);panel.contentSize=NSSize(width:380,height:500)
        try await Task.sleep(nanoseconds:350_000_000)
        precondition(nativeWindow.frame.height == 500 && abs(nativeWindow.frame.maxY-top) < 1,"Rapid reversal must settle without moving the top")
        panel.prepareForMessageTransition(animated:true);panel.contentSize=NSSize(width:380,height:600)
        try await Task.sleep(nanoseconds:50_000_000)
        panel.close();panel.contentSize=NSSize(width:380,height:460)
        panel.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        try await Task.sleep(nanoseconds:350_000_000)
        precondition(nativeWindow.frame.height == 460,"An interrupted animation must not resize the reopened panel")
        panel.prepareForMessageTransition(animated:false);panel.contentSize=NSSize(width:380,height:400)
        precondition(nativeWindow.frame.height == 400,"Reduced-motion changes must be immediate")
        print("Native panel bounds tests passed: short-screen cap, full content, footer scrolling and compact recovery")
        print("Native message resize motion passed: intermediate frames, stable top anchor, rapid reversal, close/reopen and reduced motion")
    }
}
