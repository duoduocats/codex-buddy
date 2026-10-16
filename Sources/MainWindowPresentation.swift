import AppKit

// Track only the two managed windows. Closing an auxiliary panel must not
// demote the app, and a queued close must not undo a newer window open.
@MainActor final class MainWindowPresentation {
    private let application: NSApplication
    private let iconProvider: @MainActor () -> NSImage?
    private var icon: NSImage?
    private var windows = Set<ObjectIdentifier>()
    private var revision = 0
    init(application: NSApplication? = nil,iconProvider: (@MainActor () -> NSImage?)? = nil) {
        self.application=application ?? .shared;self.iconProvider=iconProvider ?? { Self.bundledIcon() }
    }
    static func bundledIcon(bundle:Bundle = .main)->NSImage? {
        guard let url=bundle.url(forResource:"AppIcon",withExtension:"icns"),
              let image=NSImage(contentsOf:url),
              let pixels=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        // Own the icon pixels instead of handing Dock a lazy Icon Services
        // representation of this same running application.
        let result=NSImage(cgImage:pixels,size:NSSize(width:128,height:128))
        result.isTemplate=false
        return result
    }
    static func mainMenu()->NSMenu {
        let menu=NSMenu()
        let appItem=NSMenuItem();menu.addItem(appItem)
        let actions=NSMenu();appItem.submenu=actions
        actions.addItem(withTitle:L("隐藏 Codex Buddy","Hide Codex Buddy"),action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        actions.addItem(NSMenuItem.separator())
        actions.addItem(withTitle:L("退出 Codex Buddy","Quit Codex Buddy"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem(title:L("编辑","Edit"),action:nil,keyEquivalent:"");menu.addItem(editItem)
        let edit=NSMenu(title:editItem.title);editItem.submenu=edit
        for (title,selector,key) in [(L("剪切","Cut"),"cut:","x"),(L("复制","Copy"),"copy:","c"),(L("粘贴","Paste"),"paste:","v"),(L("全选","Select All"),"selectAll:","a")] {
            edit.addItem(withTitle:title,action:NSSelectorFromString(selector),keyEquivalent:key)
        }
        let windowItem=NSMenuItem(title:L("窗口","Window"),action:nil,keyEquivalent:"");menu.addItem(windowItem)
        let window=NSMenu(title:windowItem.title);windowItem.submenu=window
        window.addItem(withTitle:L("最小化","Minimize"),action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        window.addItem(withTitle:L("关闭窗口","Close Window"),action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        return menu
    }
    func finishedLaunching(initialWindowPlanned:Bool = false) {
        guard !initialWindowPlanned else { return }
        // Register as an ordinary app during the native launch sequence.
        // Only demote after AppKit has finished registering this process.
        let ticket=revision
        DispatchQueue.main.async { [weak self] in
            guard let self,self.revision == ticket else { return };self.reconcile()
        }
    }
    func beginShowing(_ window: NSWindow) {
        windows.insert(ObjectIdentifier(window));revision += 1
        reconcile()
    }
    func didShow(_ window: NSWindow) {
        guard windows.contains(ObjectIdentifier(window)) else { return }
        let ticket=revision
        // Finish the native agent-to-foreground transition after the window
        // has entered the run loop, rather than trusting the immediate flag.
        DispatchQueue.main.async { [weak self] in
            guard let self,self.revision == ticket else { return }
            self.reconcile()
            self.application.activate(ignoringOtherApps:true)
            if !window.isMiniaturized { window.makeKeyAndOrderFront(nil) }
        }
    }
    func becameKey(_ window: NSWindow) {
        guard windows.contains(ObjectIdentifier(window)) else { return }
        reconcile()
    }
    func willClose(_ window: NSWindow) {
        guard windows.remove(ObjectIdentifier(window)) != nil else { return }
        revision += 1;reconcile()
    }
    private func reconcile() {
        let desired: NSApplication.ActivationPolicy = windows.isEmpty ? .accessory : .regular
        if application.activationPolicy() != desired {
            _=application.setActivationPolicy(desired)
        }
        guard !windows.isEmpty else { return }
        if icon == nil { icon=iconProvider() }
        if let icon { application.applicationIconImage=icon }
        // The default Dock tile observes applicationIconImage. display() is
        // for a custom content view; retain the system-owned normal tile.
    }
}
