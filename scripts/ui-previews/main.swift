import AppKit
import SwiftUI
import Combine
import ImageIO
import UniformTypeIdentifiers

final class PreviewPreferences: UserDefaults {
    private var values=[String:Any]()
    override func bool(forKey key:String)->Bool { values[key] as? Bool ?? false }
    override func object(forKey key:String)->Any? { values[key] }
    override func set(_ value:Any?,forKey key:String) { values[key]=value }
}
struct Overview: View {
    @ObservedObject var model:AppModel
    var dark:Bool
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:18) {
                Image(nsImage:DuoDrawing.image(size:NSSize(width:30,height:24),window:model.window,credits:model.credits,now:model.now,menu:true,dark:dark,menuTheme:.duoDuoCat))
                    .frame(width:34,height:24)
                    .background(Capsule().fill(Color.primary.opacity(0.07)).frame(width:42,height:28))
                Spacer()
                Image(systemName:"wifi").font(.system(size:14,weight:.medium))
                Image(systemName:"battery.100").font(.system(size:19))
                Text("12:00").font(.system(size:12,weight:.medium)).monospacedDigit()
            }.padding(.horizontal,30).frame(height:34)
                .background(Color(nsColor:.windowBackgroundColor).opacity(dark ? 0.9 : 0.8))
            UsageView(model:model,settings:{})
                .background(Color(nsColor:.windowBackgroundColor).opacity(dark ? 0.94 : 0.92),in:RoundedRectangle(cornerRadius:26,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:26,style:.continuous).stroke(Color.primary.opacity(0.09),lineWidth:0.5))
                .shadow(color:.black.opacity(dark ? 0.25 : 0.12),radius:12,x:0,y:8)
                .padding(.top,1).padding(.horizontal,20)
            Spacer().frame(height:22)
        }.frame(width:420)
            .background(LinearGradient(colors:dark ? [Color(red:0.17,green:0.21,blue:0.32),Color(red:0.12,green:0.15,blue:0.24)] : [Color(red:0.89,green:0.93,blue:1),Color(red:0.95,green:0.96,blue:0.99)],startPoint:.topLeading,endPoint:.bottomTrailing))
            .environment(\.colorScheme,dark ? .dark : .light)
    }
}
struct Themes:View {
    @ObservedObject var model:AppModel
    var body:some View {
        HStack(spacing:0) {
            ForEach(MenuBarTheme.allCases) { theme in
                VStack(spacing:16) {
                    HStack(spacing:24) {
                        ForEach([false,true],id:\.self) { percentage in
                            Image(nsImage:DuoDrawing.image(size:NSSize(width:60,height:48),window:model.window,credits:model.credits,now:model.now,menu:true,dark:true,menuShowsPercentage:percentage,menuTheme:theme))
                        }
                    }
                    Text(theme.title).font(.system(size:13,weight:.medium)).foregroundStyle(.white.opacity(0.85))
                }.frame(width:190)
            }
        }.padding(.vertical,26).padding(.horizontal,20)
            .background(Color(red:0.11,green:0.13,blue:0.19)).environment(\.colorScheme,.dark)
    }
}
@MainActor final class ScreenshotDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow?
    var model:AppModel?
    var petStore:ThemeStoreModel?
    private var eventMonitor: Any?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification:Notification) {
        let configured=Bundle.main.object(forInfoDictionaryKey:"BuddyPreviewArguments") as? [String] ?? []
        let args=CommandLine.arguments.count > 1 ? CommandLine.arguments : CommandLine.arguments+configured
        guard let outputIndex=args.firstIndex(of:"--output"),outputIndex+1<args.count else { fatalError("--output required") }
        let path=args[outputIndex+1],dark=args.contains("--dark")
        let preferences = UsagePreviewPreferences()
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if args.contains("--feed-fixtures") {
            preferences.set(try! Data(contentsOf:repository.appendingPathComponent("announcements/messages.json")),forKey:ResetReminderManager.preferencePrefix+"cache")
        }
        let model=AppModel(preferences:preferences,client:UsageClient(credentialProvider:{fatalError("Screenshots cannot access credentials")}))
        model.useDemo()
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
        let now=calendar.date(from:DateComponents(year:2026,month:10,day:args.contains("--forecast") && !args.contains("--forecast-reference") ? 12 : args.contains("--trends") || args.contains("--forecast") || args.contains("--general") ? 11 : args.contains("--settings") ? 9 : 6,hour:args.contains("--forecast") || args.contains("--fidelity-reference") ? 12 : args.contains("--trends") || args.contains("--general") ? 0 : args.contains("--settings") ? 21 : 12,minute:args.contains("--forecast") ? 5 : args.contains("--fidelity-reference") ? 0 : args.contains("--trends") || args.contains("--general") ? 5 : 0))!
        model.now=now;model.updated=now;model.statisticsUpdated=now
        model.usage=UsageResponse(rateLimits:LimitBucket(limitId:"codex",limitName:nil,primary:LimitWindow(usedPercent:32,windowDurationMins:10080,resetsAt:now.addingTimeInterval(396000).timeIntervalSince1970),secondary:nil,planType:"test"),rateLimitsByLimitId:nil,rateLimitResetCredits:ResetCredits(availableCount:3))
        model.statistics = .demo(now:now);model.menuBarTheme = .duoDuoCat
        model.menuShowsPercentage = args.contains("--percentage")
        model.challenge.useDemo(now:now)
        if args.contains("--feed-fixtures") {
            let document = try! TiboChallengeDocument.decode(Data(contentsOf:repository.appendingPathComponent("announcements/tibo-28.json")))
            model.challenge.useDemo(now:now,document:document)
        }
        model.showResetDetails = true;model.resetDetailsOnlySoonest = true;model.resetExpiryWindowDays = 7
        model.resetCreditDetails = .init(availableCount:3,credits:[
            .init(expiresAt:now.addingTimeInterval(2*86_400)),
            .init(expiresAt:now.addingTimeInterval(5*86_400)),
            .init(expiresAt:now.addingTimeInterval(14*86_400))])
        if args.contains("--without-today"), let statistics = model.statistics {
            let formatter = DateFormatter();formatter.calendar = calendar;formatter.locale = Locale(identifier:"en_US_POSIX")
            formatter.timeZone = calendar.timeZone;formatter.dateFormat = "yyyy-MM-dd"
            let today = formatter.string(from:now)
            model.statistics = UsageStatistics(lifetimeTokens:statistics.lifetimeTokens,peakDailyTokens:statistics.peakDailyTokens,
                longestRunningTurnSec:statistics.longestRunningTurnSec,longestStreakDays:statistics.longestStreakDays,
                currentStreakDays:statistics.currentStreakDays,daily:statistics.daily?.filter { $0.day != today })
        }
        if args.contains("--trends") {
            var civil=Calendar(identifier:.gregorian);civil.timeZone = .autoupdatingCurrent
            let formatter=DateFormatter();formatter.calendar=civil;formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=civil.timeZone;formatter.dateFormat="yyyy-MM-dd"
            let end=civil.date(byAdding:.day,value:-1,to:now)!
            let last: [Int64] = [65,82,54,76,98,125,162]
            let shape: [Int64] = [16,18,22,24,26,20,31,29,37,41,47,54,65,74,69,84,81,98,91,100,114,110,110,123,117,126,142,149,162]
            let rows=(0..<132).map { index -> DailyTokenUsage in
                let date=civil.date(byAdding:.day,value:index-131,to:end)!
                let value: Int64
                if args.contains("--fidelity-reference") {
                    value = index >= 103 ? shape[index-103]*1_000_000 : index%13 == 0 ? 0 : Int64((index*17)%240+15)*125_000
                } else {
                    value = index >= 125 ? last[index-125]*1_000_000 : index%13 == 0 ? 0 : Int64((index*17)%240+15)*250_000
                }
                return .init(day:formatter.string(from:date),tokens:value)
            }
            if args.contains("--fidelity-reference") { precondition(shape.reduce(Int64(0),+) == 2180) }
            precondition(rows.reduce(Int64(0)) { $0+$1.tokens } <= 4_860_000_000,"Synthetic annual records must fit within lifetime tokens")
            model.statistics = .init(lifetimeTokens:4_860_000_000,peakDailyTokens:320_000_000,longestRunningTurnSec:22500,longestStreakDays:24,currentStreakDays:9,daily:args.contains("--trends-empty") ? nil : rows)
        }
        if args.contains("--forecast") {
            let reset=now.addingTimeInterval(18*3600)
            func quota(_ used: Double) -> UsageResponse {
                UsageResponse(rateLimits:LimitBucket(limitId:"codex",limitName:nil,
                    primary:LimitWindow(usedPercent:used,windowDurationMins:10080,resetsAt:reset.timeIntervalSince1970),
                    secondary:nil,planType:"test"),rateLimitsByLimitId:nil,rateLimitResetCredits:nil)
            }
            let account=String(repeating:"a",count:64)
            model.usage=quota(70);model.forecastIdentity=account;model.forecastUpdated=now
            model.forecastObservations=(0...72).flatMap { index in
                UsageForecastObservation.sanitized(usage:quota(58+Double(index)/6),accountKey:account,
                    at:now.addingTimeInterval(-6*3600+Double(index)*300))
            }
            if args.contains("--forecast-extra") { model.demoForecastExtraDate=now.addingTimeInterval(9*3600) }
            if args.contains("--forecast-cold") { model.forecastObservations=[] }
            if args.contains("--forecast-stale") { model.forecastUpdated=now.addingTimeInterval(-600) }
        }
        self.model=model
        let root:AnyView
        if args.contains("--challenge") { root=AnyView(TiboChallengeView(manager:model.challenge).environment(\.colorScheme,dark ? .dark : .light).frame(width:args.contains("--minimum") ? 780 : 960,height:args.contains("--minimum") ? 600 : 760)) }
        else if args.contains("--settings") {
            let page: BuddyPage = args.contains("--pets") ? .pets : args.contains("--messages") || args.contains("--activities") ? .messages : args.contains("--general") || args.contains("--about") ? .general : .overview
            if args.contains("--no-messages") { model.reminders.setMessagesEnabled(false) }
            model.showResetDetails = args.contains("--details")
            if args.contains("--history") { model.now = model.challenge.document.end;model.challenge.useDemo(now:model.now,document:model.challenge.document) }
            let updatePreferences = UsagePreviewPreferences()
            if page == .general { updatePreferences.set(now,forKey:"updates.lastSuccessfulCheck") }
            let previewUpdates = UpdateManager(defaults:updatePreferences,repository:page == .general ? "duoduocats/codex-buddy" : "",
                installOperation:{ _,_ in throw UpdateInstallFailure.verification })
            let petPreferences=UsagePreviewPreferences()
            if args.contains("--pets") && !args.contains("--pets-all-sources") {
                petPreferences.set(try! JSONEncoder().encode(PetSource.defaults.map { source in
                    var item=source;item.enabled=["huaqing","cutechen","senyo"].contains(item.id);return item
                }),forKey:"pets.sources")
            }
            let petRoot=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("buddy-pets-ui-"+UUID().uuidString,isDirectory:true)
            try! FileManager.default.createDirectory(at:petRoot,withIntermediateDirectories:false)
            let controller=BuddyPetsController(factory:{
                var tagStore:PetTagStore?
                if let i=args.firstIndex(of:"--tag-dir"),args.count > i+1 {
                    let original=URL(fileURLWithPath:args[i+1],isDirectory:true),copy=petRoot.appendingPathComponent("tags",isDirectory:true)
                    try! FileManager.default.copyItem(at:original,to:copy)
                    let tp=UsagePreviewPreferences();tp.set(true,forKey:"tags.localPreview")
                    tagStore=PetTagStore(preferences:tp,client:PetTagPreviewClient(),cache:PetCatalogCache(directory:copy))
                }
                let store=ThemeStoreModel(preferences:petPreferences,cacheDirectory:petRoot.appendingPathComponent("cache"),tags:tagStore,libraryRoot:petRoot,
                    openURL:{ _ in false },openCodexURL:{ _ in .failure(.failed) })
                self.petStore=store;return store
            })
            root=AnyView(SettingsView(model:model,login:LoginModel(preview:true),updates:previewUpdates,pets:controller,
                initialPage:page,initialUsageSubpage:args.contains("--forecast") ? .forecast : args.contains("--trends") ? .trends : .display,
                trendInteraction:args.contains("--hover-fixture") ? syntheticHover() : nil).environment(\.colorScheme,dark ? .dark : .light)
                .frame(width:args.contains("--minimum") ? SettingsView.minimumSize.width : SettingsView.width,
                       height:args.contains("--minimum") ? SettingsView.minimumSize.height : SettingsView.preferredHeight(for:page)))
        }
        else if args.contains("--themes") { root=AnyView(Themes(model:model)) }
        else { root=AnyView(Overview(model:model,dark:dark)) }
        let hosting=NSHostingView(rootView:root)
        hosting.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
        let size=hosting.fittingSize
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:args.contains("--interactive") ? [.titled,.closable,.miniaturizable,.resizable] : [.borderless],backing:.buffered,defer:false)
        window.appearance=hosting.appearance;window.contentView=hosting;window.isReleasedWhenClosed=false;self.window=window
        window.title="Codex Buddy · UI Preview";window.center()
        window.acceptsMouseMovedEvents=true
        if args.contains("--debug-pointer") {
            eventMonitor=NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.mouseEntered,.mouseExited,.keyDown]) { [weak self] event in
                if event.window?.windowNumber == self?.window?.windowNumber {
                    print("Synthetic window event type: \(event.type.rawValue)")
                }
                return event
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds:600_000_000)
            if args.contains("--pets") {
                let deadline=Date().addingTimeInterval(50)
                while self.petStore?.loading == true && Date() < deadline { try? await Task.sleep(nanoseconds:100_000_000) }
                if args.contains("--pets-detail"),let store=self.petStore,let theme=store.themes.first(where:{$0.name.localizedCaseInsensitiveContains("Bella")}) ?? store.themes.first {
                    store.select(theme)
                    let detailDeadline=Date().addingTimeInterval(35)
                    while store.preparing && Date() < detailDeadline { try? await Task.sleep(nanoseconds:100_000_000) }
                    precondition(store.sheet != nil,"Public pet detail did not load")
                }
                try? await Task.sleep(nanoseconds:4_000_000_000)
                print("Public catalog UI: \(self.petStore?.themes.count ?? 0) entries; \(self.petStore?.sourceErrors.count ?? 0) unavailable sources")
            }
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) else {fatalError("Snapshot unavailable")}
            hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
            guard let cg=bitmap.cgImage else {fatalError("Snapshot image unavailable")}
            let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(destination,cg,nil)
            precondition(CGImageDestinationFinalize(destination))
            let bytes=try! Data(contentsOf:URL(fileURLWithPath:path))
            var clean=Data(bytes.prefix(8)),offset=8
            while offset+12 <= bytes.count {
                let count=bytes[offset..<offset+4].reduce(0) { ($0<<8)|Int($1) }
                let end=offset+count+12
                precondition(end<=bytes.count)
                let kind=String(data:bytes[offset+4..<offset+8],encoding:.ascii)!
                if !["eXIf","tEXt","zTXt","iTXt"].contains(kind) { clean.append(bytes[offset..<end]) }
                offset=end
            }
            precondition(offset==bytes.count)
            try! clean.write(to:URL(fileURLWithPath:path))
            print("Native synthetic UI image: \(cg.width) × \(cg.height)")
            if !args.contains("--interactive") { exit(0) }
        }
    }
}
@MainActor private func syntheticHover() -> UsageTrendInteraction {
    let value=UsageTrendInteraction();value.hover("2026-10-10",active:true);return value
}

MainActor.assumeIsolated {
    let app=NSApplication.shared;app.setActivationPolicy(.regular)
    let menu=NSMenu();let application=NSMenuItem();menu.addItem(application)
    let actions=NSMenu();application.submenu=actions
    actions.addItem(withTitle:"Quit Preview",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    app.mainMenu=menu
    let delegate=ScreenshotDelegate();app.delegate=delegate
    withExtendedLifetime(delegate) { app.run() }
}
