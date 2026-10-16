import AppKit
import SwiftUI
import ServiceManagement

@MainActor final class SyntheticLoginService: LoginItemServicing {
    var status: SMAppService.Status = .enabled
    var registrations=0,removals=0,opened=0
    var nextStatus: SMAppService.Status = .enabled
    var error: Error?
    func register() async throws {
        registrations += 1;try await Task.sleep(nanoseconds:2_000_000)
        status=nextStatus;if let error { throw error }
    }
    func unregister() async throws { removals += 1;status = .notRegistered;if let error { throw error } }
    func openSettings() { opened += 1 }
}

@main struct SettingsServicesTests {
    static func check(_ condition: Bool,_ message: String = "Regression check failed",line: Int = #line) { if !condition { fputs("Failed at line \(line): \(message)\n",stderr);fatalError(message) } }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let service=SyntheticLoginService(),login=LoginModel(preview:true,service:nil)
        login.set(true);check(login.enabled)
        let real=LoginModel(service:service)
        check(real.enabled)
        service.status = .notRegistered;real.refresh()
        check(!real.enabled,"External removal must immediately replace the cached ON state")
        real.set(true);real.set(true);await real.finishUpdate()
        check(real.enabled && service.registrations == 1 && !real.updating,"Registration is single-flight")
        service.status = .requiresApproval;real.refresh()
        check(!real.enabled && real.requiresApproval && real.message != nil)
        real.set(true)
        check(service.opened == 1 && service.registrations == 1 && service.removals == 0,"Approval must use System Settings without re-registering or overriding removal")
        service.status = .enabled;real.refresh();check(real.enabled && !real.requiresApproval && real.message == nil)
        real.set(false);await real.finishUpdate();check(!real.enabled && service.removals == 1)
        service.error=CocoaError(.fileWriteNoPermission);service.nextStatus = .notRegistered
        real.set(true);await real.finishUpdate()
        check(!real.enabled && real.message != nil,"A failed registration must never leave an ON switch")
        service.nextStatus = .enabled
        real.set(true);await real.finishUpdate()
        check(real.enabled && real.message == nil,"An already-completed registration error must reflect actual system status")
        service.error=nil;service.status = .notRegistered;service.nextStatus = .requiresApproval
        real.set(true);await real.finishUpdate()
        check(!real.enabled && real.requiresApproval)
        print("Login checks passed: external removal, single-flight re-enable, approval handoff, failures and truthful status")

        let root=URL(fileURLWithPath:"/private/tmp/buddy-storage-tests-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let app=root.appendingPathComponent("Fixture.app"),prefs=root.appendingPathComponent("settings.plist")
        try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true)
        try Data(repeating:1,count:100).write(to:app.appendingPathComponent("fixture"))
        let saved=Data("synthetic saved settings and message history".utf8);try saved.write(to:prefs)
        let cache=PetCatalogCache(directory:root.appendingPathComponent("Buddy/Pets"))
        try await cache.write(Data(repeating:0,count:1234),name:"fixture.json")
        let policy=ApplicationStorage(application:app,preferencesFile:prefs,cache:cache)
        let result=try await policy.snapshot()
        check(result.applicationBytes == 100 && result.dataBytes == saved.count && result.cacheBytes == 1234)
        try Data(repeating:0,count:4096).write(to:prefs,options:.atomic)
        check(try await policy.snapshot().dataBytes == 4096,"Refreshing storage must re-read changed preference metadata")
        try saved.write(to:prefs,options:.atomic)
        let tooSmall=await cache.read("fixture.json",limit:100);check(tooSmall == nil)
        do { try await cache.write(Data(),name:"../settings.plist");preconditionFailure("Unsafe cache filename accepted") } catch {}
        let outside=root.appendingPathComponent("installed-pet.png");try saved.write(to:outside)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("Buddy/Pets/linked.json"),withDestinationURL:outside)
        check(try await cache.byteCount() == 1234,"Size scan must not follow a symlink outside the app cache")
        try await cache.clear()
        check(try Data(contentsOf:prefs) == saved && Data(contentsOf:outside) == saved)
        check(try await cache.byteCount() == 0)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("Buddy/Pets"),withDestinationURL:app)
        do { try await cache.clear();preconditionFailure("A symlink cache root must not be cleared") } catch {}
        check(FileManager.default.fileExists(atPath:app.appendingPathComponent("fixture").path))
        try FileManager.default.removeItem(at:root.appendingPathComponent("Buddy/Pets"))
        try await cache.write(Data(repeating:0,count:99),name:"fixture.json")
        let memory=UsagePreviewPreferences()
        let disabled=PetSource.defaults.map { source -> PetSource in var source=source;source.enabled=false;return source }
        memory.set(try JSONEncoder().encode(disabled),forKey:"pets.sources")
        let theme=PetTheme(remoteID:"synthetic",sourceID:"synthetic",name:"Synthetic Cat",summary:"Fixture",author:"Tester",license:"CC0",category:"Cats",
            manifestURL:URL(string:"https://example.com/pet.json")!,websiteURL:URL(string:"https://example.com/cat")!)
        let store=ThemeStoreModel(preferences:memory,cacheDirectory:root.appendingPathComponent("Buddy/Pets"),libraryRoot:root)
        let controller=BuddyPetsController(factory:{store});controller.setVisible(true)
        for _ in 0..<50 where store.loading { try await Task.sleep(nanoseconds:5_000_000) }
        store.usePreview(themes:[theme]);store.toggleFavorite(theme);controller.setVisible(false)
        let predictionCache=UsageForecastCache(directory:root.appendingPathComponent("Buddy/UsageForecast"))
        _ = try await predictionCache.record(usage:.demo,accountKey:String(repeating:"a",count:64),at:Date())
        let forecastBytes=try await predictionCache.byteCount();check(forecastBytes > 0)
        let storagePolicy=ApplicationStorage(application:app,preferencesFile:prefs,cache:cache,forecastCache:predictionCache)
        check(try await storagePolicy.snapshot().forecastBytes == forecastBytes,"Own forecast history belongs to app storage accounting")
        let storage=ApplicationStorageModel(storage:storagePolicy)
        storage.clear(using:controller,includingUsageHistory:true);await storage.finish()
        check(storage.snapshot?.cacheBytes == 0 && storage.snapshot?.forecastBytes == 0 && !storage.clearing && store.favorites.map(\.id) == [theme.id])
        check(try Data(contentsOf:prefs) == saved && Data(contentsOf:outside) == saved,"Cleaning must preserve user data and installed pets")
        print("Storage checks passed: measured sizes, bounds, symlink refusal, cache-only cleanup, saved settings/history and favorites")

        NSApplication.shared.setActivationPolicy(.regular);NSApp.finishLaunching()
        let standardMenu=MainWindowPresentation.mainMenu()
        check(standardMenu.items.first?.submenu?.items.contains(where:{ $0.action == #selector(NSApplication.terminate(_:)) && $0.keyEquivalent == "q" }) == true,"Ordinary app menu must support native quit")
        check(standardMenu.items.last?.submenu?.items.contains(where:{ $0.action == #selector(NSWindow.performClose(_:)) && $0.keyEquivalent == "w" }) == true,"Close routes through the managed window delegate")
        NSApp.mainMenu=standardMenu
        let iconURL=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns")
        let package=root.appendingPathComponent("IconFixture.app")
        try FileManager.default.createDirectory(at:package.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:iconURL,to:package.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        let plist:[String:Any]=["CFBundleIdentifier":"com.example.buddy.iconfixture","CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:package.appendingPathComponent("Contents/Info.plist"))
        let loadedIcon=MainWindowPresentation.bundledIcon(bundle:Bundle(url:package)!)
        check(loadedIcon?.size == NSSize(width:128,height:128) && loadedIcon?.isTemplate == false,"Dock icon is owned package pixels, independent of Workspace registration")
        let icon=NSImage(size:NSSize(width:32,height:32),flipped:false) { rect in NSColor.blue.setFill();rect.fill();return true }
        _=icon.tiffRepresentation
        func hasFixtureIcon() -> Bool {
            guard let image=NSApp.applicationIconImage,let actual=image.tiffRepresentation,let expected=icon.tiffRepresentation,
                  let bitmap=NSBitmapImageRep(data:actual),let reference=NSBitmapImageRep(data:expected),
                  let pixel=bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)?.usingColorSpace(.sRGB),
                  let target=reference.colorAt(x:reference.pixelsWide/2,y:reference.pixelsHigh/2)?.usingColorSpace(.sRGB) else { return false }
            return image.size == icon.size && abs(pixel.redComponent-target.redComponent) < 0.01 &&
                abs(pixel.greenComponent-target.greenComponent) < 0.01 && abs(pixel.blueComponent-target.blueComponent) < 0.01
        }
        let presenter=MainWindowPresentation(iconProvider:{ icon })
        let first=NSWindow(contentRect:NSRect(x:0,y:0,width:320,height:240),styleMask:[.titled],backing:.buffered,defer:false)
        let second=NSWindow(contentRect:NSRect(x:0,y:0,width:320,height:240),styleMask:[.titled],backing:.buffered,defer:false)
        let auxiliary=NSWindow(contentRect:NSRect(x:0,y:0,width:100,height:100),styleMask:[.borderless],backing:.buffered,defer:false)
        first.isReleasedWhenClosed=false;second.isReleasedWhenClosed=false;auxiliary.isReleasedWhenClosed=false
        presenter.beginShowing(first);presenter.didShow(first)
        check(NSApp.activationPolicy() == .regular && hasFixtureIcon(),"Dock presentation must retain the supplied icon pixels")
        check(NSApp.dockTile.size.width > 0 && NSApp.dockTile.size.height > 0,"Foreground app must have a native Dock tile")
        presenter.willClose(auxiliary)
        check(NSApp.activationPolicy() == .regular,"Auxiliary windows must never remove the app from Dock")
        presenter.beginShowing(second);presenter.willClose(first)
        check(NSApp.activationPolicy() == .regular,"One remaining managed window keeps foreground presentation")
        presenter.willClose(second);check(NSApp.activationPolicy() == .accessory)
        presenter.beginShowing(first);presenter.didShow(first);presenter.willClose(first)
        await Task.yield()
        check(NSApp.activationPolicy() == .accessory,"Queued show must not resurrect a closed window's Dock icon")
        presenter.beginShowing(first);presenter.didShow(first);presenter.willClose(first)
        presenter.beginShowing(second);presenter.didShow(second)
        await Task.yield()
        check(NSApp.activationPolicy() == .regular,"A newer open wins over an older close")
        NSApp.applicationIconImage=nil;presenter.becameKey(second)
        check(hasFixtureIcon(),"Refocusing must restore an unset application icon")
        presenter.willClose(second)
        print("Dock presentation checks passed: owned package pixels and native menu, auxiliary close, two windows, queued close/reopen and focus recovery")
        let container=NSView(frame:NSRect(x:0,y:0,width:960,height:700))
        let pages=SettingsPagesHost.Coordinator()
        var made=[BuddyPage:Int]()
        func content(_ page: BuddyPage) -> AnyView { made[page,default:0] += 1;return AnyView(Text(page.title)) }
        for _ in 0..<5 { for page in BuddyPage.allCases { pages.show(page,in:container,content:content) } }
        check(made.values.allSatisfy { $0 == 1 } && made.count == 4 && container.subviews.count == 1,"Revisit hosts must be reused and hidden pages must not participate in layout")
        print("Navigation checks passed: one host per page, retained page state and only visible-page layout")

        var large=[PetTheme]()
        for i in 0..<10_000 { var item=theme;item.remoteID="fixture-\(i)";item.name="Cat \(10_000-i)";item.author=i % 2 == 0 ? "Even Tester" : "Odd Tester";large.append(item) }
        let engine=PetSearchEngine(),snapshot=PetSearchSnapshot(themes:large,favorites:[large[0]],popularity:[:],names:["synthetic":"Fixture source"])
        let request=PetSearchRequest(revision:1,query:"Even Tester",sourceID:"",byInstalls:false,favoritesOnly:false)
        let start=ProcessInfo.processInfo.systemUptime
        let found=try await engine.query(request,snapshot:snapshot)
        let buildMS=1000*(ProcessInfo.processInfo.systemUptime-start)
        let legacyStart=ProcessInfo.processInfo.systemUptime
        var expected=[PetTheme]()
        for _ in 0..<10 {
            expected=large.filter { [$0.name,$0.author,$0.summary,$0.category,"Fixture source"].contains { $0.localizedCaseInsensitiveContains(request.query) } }.sorted {
                let order=$0.name.localizedStandardCompare($1.name);return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        }
        let legacyMS=1000*(ProcessInfo.processInfo.systemUptime-legacyStart)
        check(found == expected && found.count == 5000)
        let cachedStart=ProcessInfo.processInfo.systemUptime
        var cached=[PetTheme]()
        for _ in 0..<10 { cached=try await engine.query(request,snapshot:snapshot) }
        let cachedMS=1000*(ProcessInfo.processInfo.systemUptime-cachedStart)
        check(cached == expected)
        var favorites=request;favorites.query="";favorites.favoritesOnly=true
        check(try await engine.query(favorites,snapshot:snapshot).map(\.id) == [large[0].id])
        var none=request;none.sourceID="other";check(try await engine.query(none,snapshot:snapshot).isEmpty)
        var changed=snapshot;changed.themes=[];changed.favorites=[]
        var newer=request;newer.revision=2
        check(try await engine.query(newer,snapshot:changed).isEmpty,"Data revisions invalidate search snapshots")
        print(String(format:"Synthetic 10,000-pet search: first background index %.1fms, 10 old-style queries %.1fms, 10 cached queries %.1fms",buildMS,legacyMS,cachedMS))
    }
}
