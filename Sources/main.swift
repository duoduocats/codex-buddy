import AppKit
import SwiftUI
import Combine
import Darwin

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    var item: NSStatusItem!
    let popover = QuotaPanel()
    var usageHosting: NSHostingController<UsageView>?
    var settingsWindow: NSWindow?
    var subscription: AnyCancellable?
    private var updateSubscription: AnyCancellable?
    private var lastStatusKey = ""
    var appearanceObservation: NSKeyValueObservation?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") { selfTest(); return }
        if CommandLine.arguments.contains("--snapshot") { snapshot();return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier:Bundle.main.bundleIdentifier ?? "com.duoduocat.codexbuddy").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first, !CommandLine.arguments.contains("--ui-check"), !CommandLine.arguments.contains("--performance-check") { existing.activate(options:[]);NSApp.terminate(nil);return }
        item = NSStatusBar.system.statusItem(withLength:34)
        model.reminders.onOpenPanel = { [weak self] in
            guard let self else { return }
            if !self.popover.isShown { self.togglePopover() }
        }
        item.button?.target = self;item.button?.action = #selector(togglePopover)
        appearanceObservation = item.button?.observe(\.effectiveAppearance, options:[.new]) { [weak self] _,_ in
            DispatchQueue.main.async { self?.updateStatus() }
        }
        let hosting = NSHostingController(rootView:UsageView(model:model,settings:{ [weak self] in self?.showSettings() },sharePresentationChanged:{ [weak self] presenting in self?.popover.isPresentingAuxiliaryUI = presenting }))
        hosting.sizingOptions = []
        usageHosting = hosting
        popover.contentViewController = hosting
        popover.onClose = { [weak self] in self?.model.setPanelVisible(false) }
        subscription = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async {
            self?.updateStatus()
            if self?.popover.isShown == true { self?.resizePopover() }
        } }
        updateSubscription = UpdateManager.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async {
            if self?.popover.isShown == true { self?.resizePopover() }
        } }
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(wake),name:NSWorkspace.didWakeNotification,object:nil)
        updateStatus()
        if CommandLine.arguments.contains("--ui-check") { model.useDemo() }
        else { model.start(demo:CommandLine.arguments.contains("--performance-check")) }
        if !CommandLine.arguments.contains("--ui-check"), !CommandLine.arguments.contains("--performance-check") { UpdateManager.shared.start() }
        if CommandLine.arguments.contains("--performance-check") {
            let cpuStart=clock(), wallStart=ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.asyncAfter(deadline:.now()+60) {
                let cpu=Double(clock()-cpuStart)/Double(CLOCKS_PER_SEC)
                let wall=ProcessInfo.processInfo.systemUptime-wallStart
                var usage=rusage();getrusage(RUSAGE_SELF,&usage)
                print(String(format:"Synthetic idle: %.2f%% average CPU over %.1fs; peak RSS %.1f MiB",100*cpu/wall,wall,Double(usage.ru_maxrss)/1048576))
                self.model.client.stop();exit(0)
            }
        }
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { self.togglePopover() }
        }
        if CommandLine.arguments.contains("--ui-check") {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                self.togglePopover()
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                    fputs("Popover opened: \(self.popover.isShown)\n",stderr)
                    fputs("Status frame: \(String(describing:self.item.button?.window?.frame)); popover: \(String(describing:self.popover.contentViewController?.view.window?.frame))\n",stderr)
                    precondition(self.popover.isShown,"Popover must open")
                    self.showSettings()
                    fputs("Settings visible: \(self.settingsWindow?.isVisible == true)\n",stderr)
                    precondition(self.settingsWindow?.isVisible == true,"Settings must open")
                    precondition(NSRunningApplication.current.activationPolicy == .regular,"Settings must show a Dock icon")
                    let originalWindow = self.settingsWindow
                    self.showSettings()
                    precondition(self.settingsWindow === originalWindow,"Repeated opens must reuse the settings window")
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                        fputs("Popover closed: \(!self.popover.isShown)\n",stderr)
                        precondition(!self.popover.isShown,"Popover must close")
                        self.settingsWindow?.close()
                        precondition(NSRunningApplication.current.activationPolicy == .accessory,"Closing settings must hide the Dock icon")
                        precondition(self.item.button != nil,"Closing settings must preserve the status item")
                        self.showSettings()
                        precondition(self.settingsWindow?.isVisible == true,"Settings must reopen")
                        precondition(NSRunningApplication.current.activationPolicy == .regular,"Reopening settings must restore the Dock icon")
                        self.settingsWindow?.miniaturize(nil)
                        precondition(NSRunningApplication.current.activationPolicy == .regular,"Minimized settings must keep the Dock icon")
                        self.showSettings()
                        precondition(self.settingsWindow?.isMiniaturized == false,"Opening settings must restore a minimized window")
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                            self.settingsWindow?.performClose(nil)
                            precondition(NSRunningApplication.current.activationPolicy == .accessory,"Window close action must hide the Dock icon")
                            print("Native UI checks passed: status item, popover, settings, Dock visibility, close/reopen and minimized recovery")
                            self.model.client.stop();exit(0)
                        }
                    }
                }
            }
        }
    }
    func updateStatus() {
        let dark = item.button?.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
        let key = "\(model.window?.remaining ?? -1)|\(model.window?.countdown(now:model.now) ?? "—")|\(model.credits ?? -1)|\(model.stale)|\(dark)|\(model.menuShowsPercentage)|\(model.menuBarTheme.rawValue)"
        guard key != lastStatusKey else { return }
        lastStatusKey = key
        item.button?.image = DuoDrawing.image(size:.init(width:30,height:24),window:model.window,credits:model.credits,now:model.now,menu:true,stale:model.stale,dark:dark,menuShowsPercentage:model.menuShowsPercentage,menuTheme:model.menuBarTheme)
        let remaining = model.window.map { String(format:"%.0f%%",$0.remaining) } ?? L("未知", "Unknown")
        let reset = model.window?.countdown(now:model.now) ?? "—"
        let credits = model.credits.map(String.init) ?? L("未知", "Unknown")
        item.button?.toolTip = L("ChatGPT / Codex · 剩余 \(remaining) · \(reset) 后重置 · 可用重置 \(credits) 次", "ChatGPT / Codex · \(remaining) remaining · Resets in \(reset) · \(credits) available resets") + (model.stale ? L(" · 数据待更新", " · Out of date") : "")
        item.button?.setAccessibilityLabel(item.button?.toolTip)
    }
    @objc func togglePopover() {
        if popover.isShown { closePopover() }
        else if let button = item.button {
            model.now = Date()
            model.setPanelVisible(true)
            if model.updated == nil || Date().timeIntervalSince(model.updated!) > 5 { model.refresh(includeStatistics:false) }
            NSApp.activate(ignoringOtherApps:true)
            resizePopover()
            // NSStatusBarButton can be flipped: its visual bottom is then maxY.
            let below: NSRectEdge = button.isFlipped ? .maxY : .minY
            popover.show(relativeTo:button.bounds,of:button,preferredEdge:below)
        }
    }
    func resizePopover() {
        guard let hosting = usageHosting else { return }
        let size = hosting.sizeThatFits(in:NSSize(width:380,height:1600))
        if size.height > 0 && (abs(popover.contentSize.height-size.height) > 1 || popover.contentSize.width != 380) { popover.contentSize = NSSize(width:380,height:size.height) }
    }
    func closePopover() {
        popover.close()
    }
    @objc func wake() { model.refresh(includeStatistics:false);model.reminders.check(force:true);UpdateManager.shared.check(manual:false) }
    func showSettings() {
        closePopover()
        if settingsWindow == nil {
            let visible = NSScreen.main?.visibleFrame
            let height = min(SettingsView.height,visible.map { max(SettingsView.minimumSize.height,$0.height-80) } ?? SettingsView.height)
            let w = NSWindow(contentRect:NSRect(x:0,y:0,width:SettingsView.width,height:height),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            w.title = L("设置", "Settings");w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentMinSize = SettingsView.minimumSize
            w.contentMaxSize = NSSize(width:980,height:CGFloat.greatestFiniteMagnitude)
            w.collectionBehavior.insert(.fullScreenNone)
            w.titlebarAppearsTransparent = true;w.titlebarSeparatorStyle = .none
            let hosting = NSHostingView(rootView:SettingsView(model:model))
            hosting.sizingOptions = []
            hosting.autoresizingMask = [.width,.height]
            w.contentView = hosting;w.center();settingsWindow=w
        }
        NSApp.setActivationPolicy(.regular)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps:true);settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
    func windowWillUseStandardFrame(_ window:NSWindow,defaultFrame:NSRect) -> NSRect {
        var frame = defaultFrame
        frame.size.width = SettingsView.width
        frame.origin.x = min(max(window.frame.minX,defaultFrame.minX),defaultFrame.maxX-frame.width)
        return frame
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { showSettings() };return true
    }
    func applicationWillTerminate(_ notification: Notification) { model.reminders.stop();model.client.stop() }
    func selfTest() {
        let now = Date(timeIntervalSince1970:1000)
        precondition(LimitWindow(usedPercent:32,windowDurationMins:300,resetsAt:15400).countdown(now:now) == "4h")
        precondition(LimitWindow(usedPercent:110,windowDurationMins:nil,resetsAt:900).remaining == 0)
        precondition(LimitWindow(usedPercent:0,windowDurationMins:nil,resetsAt:nil).countdown(now:now) == "—")
        let fixture = Data(#"{"rateLimits":{"primary":{"usedPercent":9,"windowDurationMins":10080,"resetsAt":1791088419}},"rateLimitsByLimitId":{},"rateLimitResetCredits":{"availableCount":2,"credits":[]}}"#.utf8)
        do { let decoded = try JSONDecoder().decode(UsageResponse.self,from:fixture);precondition(decoded.buckets.count == 1 && decoded.rateLimitResetCredits?.availableCount == 2) } catch { fatalError("Decode failed") }
        print("Model checks passed");exit(0)
    }
    func snapshot(demo: Bool = true) {
        if demo { model.useDemo() }
        let directory = CommandLine.arguments.last!
        func save(_ view: NSView,_ name: String) {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent(name))
        }
        let view = NSHostingView(rootView:UsageView(model:model,settings:{}).background(Color(nsColor:.windowBackgroundColor)))
        view.appearance = NSAppearance(named:.aqua)
        view.frame = NSRect(origin:.zero,size:view.fittingSize)
        save(view,"popover.png")
        view.appearance = NSAppearance(named:.darkAqua);save(view,"popover-dark.png")
        let settings = NSHostingView(rootView:SettingsView(model:model).background(Color(nsColor:.windowBackgroundColor)));settings.frame=NSRect(origin:.zero,size:settings.fittingSize);save(settings,"settings.png")
        let icon = DuoDrawing.image(size:.init(width:300,height:240),window:model.window,credits:2,now:model.now,menu:true)
        icon.isTemplate = false
        let imageView = NSImageView(frame:NSRect(x:0,y:0,width:300,height:240));imageView.image = icon
        imageView.wantsLayer = true;imageView.layer?.backgroundColor = NSColor.white.cgColor
        save(imageView,"menu-preview.png")
        let darkIcon = DuoDrawing.image(size:.init(width:30,height:24),window:model.window,credits:2,now:model.now,menu:true,dark:true)
        let darkView = NSImageView(frame:NSRect(x:0,y:0,width:30,height:24));darkView.image = darkIcon
        darkView.wantsLayer=true;darkView.layer?.backgroundColor=NSColor(white:0.12,alpha:1).cgColor
        save(darkView,"menu-dark-actual.png")
        let iconDate = Date()
        let iconWindow = LimitWindow(usedPercent:32,windowDurationMins:300,resetsAt:iconDate.addingTimeInterval(14400).timeIntervalSince1970)
        let appIcon = NSImage(size:NSSize(width:1024,height:1024),flipped:true) { rect in
            NSColor.white.setFill();rect.fill()
            let artwork = DuoDrawing.image(size:NSSize(width:780,height:810),window:iconWindow,credits:2,now:iconDate,menu:true)
            artwork.isTemplate = false
            artwork.draw(in:NSRect(x:122,y:107,width:780,height:810))
            return true
        }
        if let data = appIcon.tiffRepresentation, let bitmap = NSBitmapImageRep(data:data) { try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent("app-icon.png")) }
        if let data=icon.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data) { try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent("menu-icon.png")) }
        for remaining in [0.0, 1, 50, 99, 99.9, 100] {
            let fixture = LimitWindow(usedPercent:100-remaining,windowDurationMins:10080,resetsAt:model.now.addingTimeInterval(198000).timeIntervalSince1970)
            for menu in [true,false] {
                let rendered = DuoDrawing.image(size:NSSize(width:300,height:300),window:fixture,credits:2,now:model.now,menu:menu)
                let preview = NSImage(size:NSSize(width:300,height:300),flipped:true) { rect in
                    NSColor.white.setFill();rect.fill();rendered.draw(in:rect);return true
                }
                if let data=preview.tiffRepresentation, let bitmap=NSBitmapImageRep(data:data) {
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent("arc-\(remaining)-\(menu ? "menu" : "detail").png"))
                }
            }
        }
        print("Snapshots saved\(demo ? " (demo data)" : " (live data)")");model.client.stop();exit(0)
    }
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
