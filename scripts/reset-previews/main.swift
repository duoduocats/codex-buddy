import AppKit
import SwiftUI
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Combine

/// Memory-only preferences isolate every preview control from the installed app.
final class PreviewPreferences: UserDefaults {
    private var values = [String:Any]()
    override func object(forKey key:String)->Any? { values[key] }
    override func bool(forKey key:String)->Bool { values[key] as? Bool ?? false }
    override func integer(forKey key:String)->Int { values[key] as? Int ?? 0 }
    override func string(forKey key:String)->String? { values[key] as? String }
    override func stringArray(forKey key:String)->[String]? { values[key] as? [String] }
    override func data(forKey key:String)->Data? { values[key] as? Data }
    override func dictionary(forKey key:String)->[String:Any]? { values[key] as? [String:Any] }
    override func set(_ value:Any?,forKey key:String) { values[key] = value }
    override func removeObject(forKey key:String) { values.removeValue(forKey:key) }
}

/// These two exact synthetic responses are the only requests the preview permits.
/// Unknown URLs fail locally rather than falling through to a network connection.
final class PreviewURLProtocol: URLProtocol {
    static let repository = "duoduocats/codex-buddy"
    static let releaseURL = "https://api.github.com/repos/\(repository)/releases/latest"
    static let policyURL = "https://github.com/\(repository)/releases/download/v2.1.0/update-policy.json"
    static let policy = Data(#"{"schemaVersion":2,"version":"2.1.0","mode":"notify"}"#.utf8)
    static var release: Data {
        let digest = SHA256.hash(data:policy).map { String(format:"%02x",$0) }.joined()
        let object: [String:Any] = ["tag_name":"v2.1.0", "html_url":"https://github.com/\(repository)/releases/tag/v2.1.0",
            "body":"Synthetic preview", "draft":false, "prerelease":false,
            "assets":[["name":"Codex-Buddy-2.1.0-arm64.dmg","state":"uploaded","size":1234,
                "browser_download_url":"https://github.com/\(repository)/releases/download/v2.1.0/Codex-Buddy-2.1.0-arm64.dmg",
                "digest":"sha256:"+String(repeating:"0",count:64)],
                ["name":"update-policy.json","state":"uploaded","size":policy.count,
                 "browser_download_url":policyURL,"digest":"sha256:"+digest]]]
        return try! JSONSerialization.data(withJSONObject:object)
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self,didFailWithError:URLError(.badURL));return }
        let data:Data
        switch url.absoluteString {
        case Self.releaseURL: data = Self.release
        case Self.policyURL: data = Self.policy
        default: client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return
        }
        let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum PreviewUpdateScenario: String,CaseIterable,Identifiable {
    case ready,downloading,failure,none
    var id:String { rawValue }
    var title:String {
        switch self {
        case .ready: return L("可下载", "Available")
        case .downloading: return L("下载中", "Downloading")
        case .failure: return L("校验失败", "Verification failed")
        case .none: return L("无更新", "No update")
        }
    }
}
enum PreviewMessageScenario: String,CaseIterable,Identifiable {
    case countdown,none
    var id:String { rawValue }
    var title:String {
        switch self {
        case .countdown: return L("带倒计时", "With countdown")
        case .none: return L("无消息", "No message")
        }
    }
    var status:ResetAnnouncementStatus? {
        switch self { case .countdown:return .scheduled;case .none:return nil }
    }
}

@MainActor final class PreviewState: ObservableObject {
    let model:AppModel
    let login = LoginModel(preview:true)
    let notificationEvent:ResetAnnouncement?
    @Published var updates:UpdateManager
    @Published var updateScenario:PreviewUpdateScenario = .ready
    @Published var messageScenario:PreviewMessageScenario = .countdown
    @Published var dark:Bool
    @Published var notesPresented = false
    @Published var notificationsPresented = false
    @Published var panelHeight:CGFloat = 825
    @Published var settingsHeight:CGFloat = 599
    var readyTask:Task<Void,Never>?
    private var modelObservation:AnyCancellable?
    private var updateObservation:AnyCancellable?
    private var measurementPending = false
    private var demoTimer:Timer?
    init(dark:Bool) {
        self.dark = dark
        let preferences = PreviewPreferences()
        model = AppModel(preferences:preferences,client:UsageClient(credentialProvider:{ fatalError("Preview never accesses credentials") }))
        model.useDemo()
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(secondsFromGMT:8*3600)!
        let now = calendar.date(from:DateComponents(year:2026,month:10,day:3,hour:0,minute:41))!
        model.now = now;model.updated = now;model.statisticsUpdated = now
        model.usage = UsageResponse(rateLimits:LimitBucket(limitId:"codex",limitName:nil,
            primary:LimitWindow(usedPercent:32,windowDurationMins:10080,resetsAt:now.addingTimeInterval(396000).timeIntervalSince1970),
            secondary:nil,planType:"demo"),rateLimitsByLimitId:nil,rateLimitResetCredits:ResetCredits(availableCount:3))
        model.statistics = .demo(now:now)
        model.menuBarTheme = .duoDuoCat
        model.reminders.useDemo(now:now,status:.scheduled)
        notificationEvent = model.reminders.upcoming
        updates = Self.manager(scenario:.ready,notes:{})
        updates = Self.manager(scenario:.ready,notes:{ [weak self] in self?.notesPresented = true })
        modelObservation = model.objectWillChange.sink { [weak self] _ in self?.scheduleMeasurement() }
        observeUpdates()
    }
    private static func manager(scenario:PreviewUpdateScenario,notes:@escaping ()->Void)->UpdateManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewURLProtocol.self]
        configuration.urlCredentialStorage = nil
        return UpdateManager(defaults:PreviewPreferences(),configuration:configuration,
            repository:PreviewURLProtocol.repository,currentVersion:scenario == .none ? "2.1.0" : "2.0.1",
            installOperation:{ _,_ in
                // A real download, package replacement, or relaunch is impossible here.
                let delay:UInt64 = scenario == .failure ? 80_000_000 : scenario == .downloading ? 60_000_000_000 : 3_000_000_000
                try await Task.sleep(nanoseconds:delay)
                throw UpdateInstallFailure.verification
            },releaseOpener:{ _ in notes() })
    }
    func selectUpdate(_ scenario:PreviewUpdateScenario) {
        readyTask?.cancel()
        updateScenario = scenario
        updates = Self.manager(scenario:scenario,notes:{ [weak self] in self?.notesPresented = true })
        observeUpdates()
        let manager = updates
        manager.check(manual:false)
        readyTask = Task {
            while manager.checking && !Task.isCancelled { try? await Task.sleep(nanoseconds:10_000_000) }
            guard !Task.isCancelled else { return }
            if scenario == .downloading || scenario == .failure { manager.installAvailable() }
        }
    }
    func selectMessage(_ scenario:PreviewMessageScenario) {
        messageScenario = scenario
        model.reminders.useDemo(now:model.now,status:scenario.status)
    }
    func waitUntilSettled() async {
        if let readyTask { await readyTask.value }
        if updateScenario == .failure {
            while updates.installing { try? await Task.sleep(nanoseconds:10_000_000) }
        }
    }
    func measure() {
        let panel = NSHostingView(rootView:UsageView(model:model,settings:{},updates:updates)
            .environment(\.colorScheme,dark ? .dark : .light)).fittingSize.height
        let settings = NSHostingView(rootView:SettingsView(model:model,login:self.login,updates:updates)
            .environment(\.colorScheme,dark ? .dark : .light)).fittingSize.height
        if panel>100,abs(panelHeight-panel)>0.5 { panelHeight=panel }
        if settings>100,abs(settingsHeight-settings)>0.5 { settingsHeight=settings }
    }
    func startInteractiveClock() {
        guard demoTimer == nil else { return }
        let sampleStart = model.now,wallStart = Date()
        demoTimer = Timer.scheduledTimer(withTimeInterval:30,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.now = sampleStart.addingTimeInterval(Date().timeIntervalSince(wallStart))
                self.model.updated = self.model.now
                self.model.statisticsUpdated = self.model.now
            }
        }
        demoTimer?.tolerance = 5
    }
    private func observeUpdates() {
        updateObservation = updates.objectWillChange.sink { [weak self] _ in self?.scheduleMeasurement() }
        scheduleMeasurement()
    }
    private func scheduleMeasurement() {
        guard !measurementPending else { return }
        measurementPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementPending = false
            self.measure()
        }
    }
}

struct PreviewMenuBar:View {
    @ObservedObject var model:AppModel
    var dark:Bool
    var body:some View {
        HStack(spacing:18) {
            Image(nsImage:DuoDrawing.image(size:NSSize(width:30,height:24),window:model.window,credits:model.credits,
                now:model.now,menu:true,dark:dark,menuShowsPercentage:model.menuShowsPercentage,menuTheme:model.menuBarTheme))
                .frame(width:34,height:24)
            Spacer()
            Image(systemName:"wifi").font(.system(size:14,weight:.medium))
            Image(systemName:"battery.100").font(.system(size:19))
            Text("00:41").font(.system(size:12,weight:.medium)).monospacedDigit()
        }.padding(.horizontal,24).frame(height:34)
            .background(Color(nsColor:.windowBackgroundColor).opacity(0.84))
    }
}

struct NotificationSamples:View {
    var event:ResetAnnouncement?
    var dismiss:(()->Void)? = nil
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text(L("消息通知预览", "Message notification preview")).font(.system(size:18,weight:.semibold))
                Spacer()
                if let dismiss { Button(L("完成", "Done"),action:dismiss) }
            }
            Text(L("示意卡片，未发送系统通知。实际外观由 macOS 控制。", "Sample only. No system notification was sent. macOS controls its actual appearance."))
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack(alignment:.top,spacing:11) {
                if let icon=BuddyBrand.applicationIcon {
                    Image(nsImage:icon).resizable().frame(width:34,height:34).clipShape(RoundedRectangle(cornerRadius:8))
                }
                VStack(alignment:.leading,spacing:4) {
                    Text("Codex Buddy").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                    Text(event?.title ?? L("消息提醒", "Message reminders"))
                        .font(.system(size:12,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                    Text(event?.body ?? "").font(.system(size:11)).fixedSize(horizontal:false,vertical:true)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.padding(13).background(Color(nsColor:.windowBackgroundColor),in:RoundedRectangle(cornerRadius:14))
                .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.1),lineWidth:0.5))
        }.padding(24).frame(width:470)
    }
}

struct PreviewCanvas:View {
    @ObservedObject var state:PreviewState
    var height:CGFloat
    var controls:Bool
    private var availableHeight:CGFloat { max(280,height-(controls ? 48 : 0)-57) }
    var body:some View {
        VStack(spacing:0) {
            if controls {
                HStack(spacing:16) {
                    Text(L("完整交互预览", "Interactive preview")).font(.system(size:13,weight:.semibold))
                    Spacer()
                    Picker(L("更新", "Update"),selection:Binding(get:{state.updateScenario},set:{state.selectUpdate($0)})) {
                        ForEach(PreviewUpdateScenario.allCases) { Text($0.title).tag($0) }
                    }.frame(width:210)
                    Picker(L("消息", "Message"),selection:Binding(get:{state.messageScenario},set:{state.selectMessage($0)})) {
                        ForEach(PreviewMessageScenario.allCases) { Text($0.title).tag($0) }
                    }.frame(width:210)
                    Toggle(L("深色", "Dark"),isOn:$state.dark).toggleStyle(.switch).fixedSize()
                    Button { state.notificationsPresented = true } label: { Image(systemName:"bell.badge") }
                        .help(L("消息通知预览", "Message notification preview"))
                }.padding(.horizontal,24).padding(.vertical,12)
                Divider()
            }
            HStack(alignment:.top,spacing:24) {
                VStack(spacing:0) {
                    PreviewMenuBar(model:state.model,dark:state.dark)
                    ScrollView(.vertical) {
                        UsageView(model:state.model,settings:{},updates:state.updates)
                            .background(Color(nsColor:.windowBackgroundColor).opacity(state.dark ? 0.94 : 0.92))
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key:PreviewPanelHeightKey.self,value:proxy.size.height)
                            })
                    }.scrollIndicators(.visible)
                        .frame(width:380,height:min(state.panelHeight,availableHeight-36))
                        .onPreferenceChange(PreviewPanelHeightKey.self) { if $0>100,abs(state.panelHeight-$0)>0.5 { state.panelHeight=$0 } }
                        .background(Color(nsColor:.windowBackgroundColor).opacity(state.dark ? 0.94 : 0.92))
                        .clipShape(RoundedRectangle(cornerRadius:22,style:.continuous))
                        .overlay(RoundedRectangle(cornerRadius:22,style:.continuous).stroke(Color.primary.opacity(0.1),lineWidth:0.5))
                        .shadow(color:.black.opacity(0.12),radius:12,x:0,y:6)
                        .padding(.top,2)
                }.frame(width:380)
                ScrollView(.vertical) {
                    SettingsView(model:state.model,onHeightChange:{ if $0>100,abs(state.settingsHeight-$0)>0.5 { state.settingsHeight=$0 } },login:state.login,updates:state.updates)
                }.scrollIndicators(.visible)
                    .frame(width:440,height:min(state.settingsHeight,availableHeight))
                    .background(Color(nsColor:.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius:18,style:.continuous))
                    .overlay(RoundedRectangle(cornerRadius:18,style:.continuous).stroke(Color.primary.opacity(0.1),lineWidth:0.5))
                    .shadow(color:.black.opacity(0.08),radius:12,x:0,y:6)
            }.padding(.horizontal,24).padding(.top,20).padding(.bottom,12)
            Spacer(minLength:0)
            HStack {
                Image(systemName:"testtube.2").font(.system(size:11))
                Text(L("模拟数据 · 消息和下载均为演示", "Sample data · Simulated messages and downloads"))
                    .font(.system(size:11)).foregroundStyle(.secondary)
                Spacer()
                Text("2.1.0 Preview").font(.system(size:11)).foregroundStyle(.secondary)
            }.padding(.horizontal,26).padding(.bottom,14)
        }.frame(width:892,height:height)
            .background(LinearGradient(colors:state.dark ? [Color(red:0.17,green:0.21,blue:0.30),Color(red:0.11,green:0.14,blue:0.21)] : [Color(red:0.88,green:0.93,blue:1),Color(red:0.96,green:0.97,blue:0.99)],startPoint:.topLeading,endPoint:.bottomTrailing))
            .environment(\.colorScheme,state.dark ? .dark : .light)
            .sheet(isPresented:$state.notesPresented) {
                VStack(alignment:.leading,spacing:14) {
                    Text(L("2.1.0 重大更新", "2.1.0 major update")).font(.title2.weight(.semibold))
                    Text(L("消息提醒与面板消息\n重大更新在展开面板直接下载\n不增加使用统计上报", "Message reminders and panel messages\nDownload major updates from the expanded panel\nNo usage telemetry added"))
                        .font(.system(size:14)).lineSpacing(7)
                    Text(L("这是本机预览，尚未发布。", "This is a local preview. It has not been published."))
                        .font(.system(size:12)).foregroundStyle(.secondary)
                    HStack { Spacer();Button(L("完成", "Done")) { state.notesPresented = false }.keyboardShortcut(.defaultAction) }
                }.padding(28).frame(width:460)
            }
            .sheet(isPresented:$state.notificationsPresented) {
                NotificationSamples(event:state.notificationEvent,dismiss:{ state.notificationsPresented = false })
                    .environment(\.colorScheme,state.dark ? .dark : .light)
            }
    }
}

private struct PreviewPanelHeightKey:PreferenceKey {
    static var defaultValue:CGFloat = 0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) { value=nextValue() }
}

final class PreviewWindow:NSWindow {
    override var canBecomeKey:Bool { true }
    override var canBecomeMain:Bool { true }
}

@MainActor final class PreviewDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow?
    var state:PreviewState?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let args = CommandLine.arguments
        func value(_ key:String)->String? { guard let i=args.firstIndex(of:key),i+1<args.count else { return nil };return args[i+1] }
        let snapshot = value("--output")
        let state = PreviewState(dark:args.contains("--dark"))
        self.state = state
        state.selectUpdate(PreviewUpdateScenario(rawValue:value("--update") ?? "ready") ?? .ready)
        state.selectMessage(PreviewMessageScenario(rawValue:value("--message") ?? "countdown") ?? .countdown)
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let height = snapshot == nil ? min(850,max(560,screenHeight-60)) : 1000
        var root:AnyView
        if args.contains("--notifications") {
            root = AnyView(NotificationSamples(event:state.notificationEvent)
                .background(Color(nsColor:.windowBackgroundColor))
                .environment(\.colorScheme,state.dark ? .dark : .light))
        } else {
            root = AnyView(PreviewCanvas(state:state,height:height,controls:snapshot == nil))
        }
        if snapshot != nil {
            root = AnyView(root.environment(\.controlActiveState,.key))
        }
        let hosting = NSHostingView(rootView:root)
        hosting.appearance = NSAppearance(named:state.dark ? .darkAqua : .aqua)
        let size = args.contains("--notifications") ? hosting.fittingSize : NSSize(width:892,height:height)
        let window = PreviewWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:snapshot == nil ? [.titled,.closable,.miniaturizable] : [.borderless],backing:.buffered,defer:false)
        window.title = "Codex Buddy 2.1.0 Preview"
        window.appearance = hosting.appearance;window.contentView = hosting;window.isReleasedWhenClosed = false
        self.window = window
        window.center();window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        if snapshot == nil { state.startInteractiveClock() }
        Task {
            await state.waitUntilSettled()
            try? await Task.sleep(nanoseconds:450_000_000)
            state.measure()
            try? await Task.sleep(nanoseconds:100_000_000)
            hosting.layoutSubtreeIfNeeded()
            let usage = NSHostingView(rootView:UsageView(model:state.model,settings:{},updates:state.updates).environment(\.colorScheme,state.dark ? .dark : .light))
            let settings = NSHostingView(rootView:SettingsView(model:state.model,login:state.login,updates:state.updates).environment(\.colorScheme,state.dark ? .dark : .light))
            print("Native content fitting: panel=\(usage.fittingSize), settings=\(settings.fittingSize), interactive viewport=\(height)")
            guard let snapshot else { return }
            Self.save(hosting:hosting,to:snapshot)
            NSApp.terminate(nil)
        }
    }
    static func save(hosting:NSView,to path:String) {
        guard let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) else { fatalError("Snapshot unavailable") }
        hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
        guard let cg=bitmap.cgImage,
              let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL,UTType.png.identifier as CFString,1,nil) else { fatalError("Snapshot unavailable") }
        CGImageDestinationAddImage(destination,cg,nil)
        precondition(CGImageDestinationFinalize(destination))
        // Keep screenshot color profile; remove identifying metadata chunks.
        let bytes=try! Data(contentsOf:URL(fileURLWithPath:path))
        var clean=Data(bytes.prefix(8)),offset=8
        while offset+12<=bytes.count {
            let count=bytes[offset..<offset+4].reduce(0) { ($0<<8)|Int($1) }
            let end=offset+count+12
            precondition(end<=bytes.count)
            let kind=String(data:bytes[offset+4..<offset+8],encoding:.ascii)!
            if !["eXIf","tEXt","zTXt","iTXt"].contains(kind) { clean.append(bytes[offset..<end]) }
            offset=end
        }
        precondition(offset==bytes.count)
        try! clean.write(to:URL(fileURLWithPath:path))
        print("Synthetic preview PNG: \(cg.width) × \(cg.height)")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}

MainActor.assumeIsolated {
    let app=NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate=PreviewDelegate();app.delegate=delegate
    withExtendedLifetime(delegate) { app.run() }
}
