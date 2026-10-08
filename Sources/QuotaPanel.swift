import AppKit

private final class RoundedPanelSurface: NSView {
    override var isOpaque: Bool { false }
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    required init?(coder:NSCoder) { fatalError("Not used") }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Arrowless status panel. The system owns its material and order-in/out animation.
@MainActor final class QuotaPanel {
    private let panel = MenuPanel(contentRect:NSRect(x:0,y:0,width:340,height:500),
        styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    private weak var anchor: NSView?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let scrollView = NSScrollView()
    private var requestedSize = NSSize(width:380,height:500)
    private var pendingHeight: CGFloat?
    private var heightUpdateScheduled = false
    private let maximumHeight: CGFloat?
    var contentViewController: NSViewController? { didSet { installContent() } }
    var onClose: (() -> Void)?
    var isPresentingAuxiliaryUI = false
    var isShown: Bool { panel.isVisible }
    var contentSize: NSSize {
        get { panel.frame.size }
        set {
            guard newValue.width.isFinite, newValue.height.isFinite,
                  newValue.width > 0, newValue.height > 0 else { return }
            let changed = requestedSize != newValue
            requestedSize = newValue
            updateSize(resetScroll:changed)
        }
    }
    init(maximumHeight: CGFloat? = nil) {
        self.maximumHeight = maximumHeight
        panel.isOpaque = false;panel.backgroundColor = .clear
        panel.hasShadow = true;panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu;panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        scrollView.drawsBackground = false;scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay;scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
    }
    // Use only the height reported by the rendered SwiftUI content. Measuring
    // again from objectWillChange can apply a stale height after the new layout.
    // Coalesce changes after SwiftUI finishes the current layout transaction.
    func setContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        pendingHeight = ceil(height)
        guard !heightUpdateScheduled else { return }
        heightUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightUpdateScheduled = false
            guard let height = self.pendingHeight else { return }
            self.pendingHeight = nil
            self.contentSize = NSSize(width:380,height:height)
        }
    }
    private func updateSize(resetScroll: Bool = false) {
        let screen = anchor?.window?.screen ?? NSScreen.main
        let availableHeight = max(1,(screen?.visibleFrame.height ?? requestedSize.height+9)-9)
        let height = min(requestedSize.height,availableHeight,maximumHeight ?? availableHeight)
        let size = NSSize(width:requestedSize.width,height:height)
        scrollView.hasVerticalScroller = height < requestedSize.height
        scrollView.documentView?.setFrameSize(requestedSize)
        if panel.frame.size != size { panel.setContentSize(size);panel.invalidateShadow() }
        panel.contentView?.layoutSubtreeIfNeeded()
        if resetScroll {
            // Message expiry, category changes and collapse must all return to
            // the top, even if the previous longer document was scrolled.
            let top = scrollView.documentView?.isFlipped == false
                ? max(0,requestedSize.height-scrollView.contentSize.height) : 0
            scrollView.contentView.scroll(to:NSPoint(x:0,y:top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if isShown { position() }
    }
    private func installContent() {
        guard let view = contentViewController?.view else { return }
        view.frame = NSRect(origin:.zero,size:requestedSize)
        view.autoresizingMask = [.width]
        scrollView.documentView = view
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame:NSRect(origin:.zero,size:contentSize))
            glass.style = .regular;glass.cornerRadius = 26;glass.contentView = scrollView
            background = glass
        } else {
            let material = NSVisualEffectView(frame:NSRect(origin:.zero,size:contentSize))
            material.material = .popover;material.blendingMode = .behindWindow;material.state = .active
            material.wantsLayer = true;material.layer?.cornerRadius = 22;material.layer?.masksToBounds = true
            material.addSubview(scrollView);background = material
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo:background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo:background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo:background.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo:background.bottomAnchor)
        ])
        // Clip the whole composition, not only the glass material. Hosting content
        // and compositor sublayers must share the same transparent outer corners.
        let surface = RoundedPanelSurface(frame:NSRect(origin:.zero,size:contentSize))
        background.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo:surface.leadingAnchor),
            background.trailingAnchor.constraint(equalTo:surface.trailingAnchor),
            background.topAnchor.constraint(equalTo:surface.topAnchor),
            background.bottomAnchor.constraint(equalTo:surface.bottomAnchor)
        ])
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = surface
        panel.invalidateShadow()
    }
    func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        anchor = view;updateSize(resetScroll:true);position()
        panel.makeKeyAndOrderFront(nil)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard self?.isPresentingAuxiliaryUI == false else { return }
                self?.close()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]) { [weak self] event in
            guard let self else { return event }
            if self.isPresentingAuxiliaryUI { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.close();return nil }
            if event.type != .keyDown && event.window !== self.panel && event.window !== self.anchor?.window && event.window?.level != .popUpMenu { self.close() }
            return event
        }
    }
    private func position() {
        guard let anchor,let window = anchor.window,let screen = window.screen else { return }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds,to:nil))
        let visible = screen.visibleFrame
        let leftAlignedX = rect.minX
        let rightAlignedX = rect.maxX-panel.frame.width
        let preferredX = leftAlignedX+panel.frame.width <= visible.maxX-8
            ? leftAlignedX : rightAlignedX
        let x = min(max(preferredX,visible.minX+8),visible.maxX-panel.frame.width-8)
        // Anchor to the menu-bar window, not the button's inset content bounds.
        let menuBarBottom = window.frame.minY
        let gap: CGFloat = 1
        let y = menuBarBottom-gap-panel.frame.height
        let scale = screen.backingScaleFactor
        panel.setFrameOrigin(NSPoint(x:(x*scale).rounded()/scale,
            y:(max(visible.minY+8,y)*scale).rounded()/scale))
    }
    func close() {
        isPresentingAuxiliaryUI = false
        onClose?()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor);self.globalMonitor=nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor);self.localMonitor=nil }
        panel.orderOut(nil)
    }
}
