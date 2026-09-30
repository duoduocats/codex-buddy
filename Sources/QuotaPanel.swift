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
    var contentViewController: NSViewController? { didSet { installContent() } }
    var onClose: (() -> Void)?
    var isPresentingAuxiliaryUI = false
    var isShown: Bool { panel.isVisible }
    var contentSize: NSSize {
        get { panel.frame.size }
        set {
            guard panel.frame.size != newValue else { return }
            panel.setContentSize(newValue)
            panel.invalidateShadow()
            if isShown { position() }
        }
    }
    init() {
        panel.isOpaque = false;panel.backgroundColor = .clear
        panel.hasShadow = true;panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu;panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
    }
    private func installContent() {
        guard let view = contentViewController?.view else { return }
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame:NSRect(origin:.zero,size:contentSize))
            glass.style = .regular;glass.cornerRadius = 26;glass.contentView = view
            background = glass
        } else {
            let material = NSVisualEffectView(frame:NSRect(origin:.zero,size:contentSize))
            material.material = .popover;material.blendingMode = .behindWindow;material.state = .active
            material.wantsLayer = true;material.layer?.cornerRadius = 22;material.layer?.masksToBounds = true
            material.addSubview(view);background = material
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo:background.leadingAnchor),
            view.trailingAnchor.constraint(equalTo:background.trailingAnchor),
            view.topAnchor.constraint(equalTo:background.topAnchor),
            view.bottomAnchor.constraint(equalTo:background.bottomAnchor)
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
        anchor = view;position()
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
