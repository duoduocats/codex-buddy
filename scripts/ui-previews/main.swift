import AppKit
import SwiftUI
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
    func applicationDidFinishLaunching(_ notification:Notification) {
        let args=CommandLine.arguments
        guard let outputIndex=args.firstIndex(of:"--output"),outputIndex+1<args.count else { fatalError("--output required") }
        let path=args[outputIndex+1],dark=args.contains("--dark")
        let model=AppModel(preferences:PreviewPreferences(),client:UsageClient(credentialProvider:{fatalError("Screenshots cannot access credentials")}))
        model.useDemo()
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
        let now=calendar.date(from:DateComponents(year:2026,month:10,day:6,hour:12,minute:0))!
        model.now=now;model.updated=now;model.statisticsUpdated=now
        model.usage=UsageResponse(rateLimits:LimitBucket(limitId:"codex",limitName:nil,primary:LimitWindow(usedPercent:32,windowDurationMins:10080,resetsAt:now.addingTimeInterval(396000).timeIntervalSince1970),secondary:nil,planType:"test"),rateLimitsByLimitId:nil,rateLimitResetCredits:ResetCredits(availableCount:3))
        model.statistics = .demo(now:now);model.menuBarTheme = .duoDuoCat
        model.challenge.useDemo(now:now)
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
        self.model=model
        let root:AnyView
        if args.contains("--challenge") { root=AnyView(TiboChallengeView(manager:model.challenge).environment(\.colorScheme,dark ? .dark : .light).frame(width:args.contains("--minimum") ? 780 : 960,height:args.contains("--minimum") ? 600 : 760)) }
        else if args.contains("--settings") { root=AnyView(SettingsView(model:model).environment(\.colorScheme,dark ? .dark : .light)) }
        else if args.contains("--themes") { root=AnyView(Themes(model:model)) }
        else { root=AnyView(Overview(model:model,dark:dark)) }
        let hosting=NSHostingView(rootView:root)
        hosting.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
        let size=hosting.fittingSize
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.appearance=hosting.appearance;window.contentView=hosting;window.isReleasedWhenClosed=false;self.window=window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {
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
            exit(0)
        }
    }
}
MainActor.assumeIsolated {
    let app=NSApplication.shared;app.setActivationPolicy(.accessory)
    let delegate=ScreenshotDelegate();app.delegate=delegate
    withExtendedLifetime(delegate) { app.run() }
}
