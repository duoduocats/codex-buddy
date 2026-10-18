import AppKit
import SwiftUI
import Combine

// Exercise both layouts even when the CI display is smaller than the test window.
private final class OverviewLayoutTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect,to screen: NSScreen?) -> NSRect { frameRect }
}

@main struct OverviewTests {
    @MainActor static func main() async throws {
        func diagnostic(_ message:String) {
            FileHandle.standardError.write(Data(("[Overview] " + message + "\n").utf8))
        }
        func check(_ condition:@autoclosure ()->Bool,_ message:String = "Unnamed overview assertion",file:StaticString = #fileID,line:UInt = #line) {
            guard condition() else {
                diagnostic("FAIL \(file):\(line): \(message)")
                preconditionFailure(message,file:file,line:line)
            }
        }
        diagnostic("start; creating NSApplication")
        NSApplication.shared.setActivationPolicy(.regular)
        check(SettingsView.preferredHeight(for:.overview) == 1000 && SettingsView.preferredHeight(for:.general) == 1000)
        check(SettingsView.fittedHeight(for:.overview,availableHeight:800) == 720,"Default must fit the available screen")
        check(SettingsView.fittedHeight(for:.overview,availableHeight:1440) == 1000,"Large screens retain tall preview space")
        let now = Date()
        let preferences = UsagePreviewPreferences()
        let recent = ResetAnnouncement(id:"recent",revision:1,type:"message",status:.completed,
            publishedAt:now.addingTimeInterval(-60),expiresAt:now.addingTimeInterval(86_400),
            titleText:.init(zh:"示例新消息",en:"Sample recent message"),bodyText:.init(zh:"模拟内容",en:"Synthetic content"))
        let expired = ResetAnnouncement(id:"history",revision:2,type:"message",status:.completed,
            publishedAt:now.addingTimeInterval(-2*86_400),expiresAt:now.addingTimeInterval(-86_400),
            titleText:.init(zh:"示例历史消息",en:"Sample historical message"),bodyText:.init(zh:"模拟内容",en:"Synthetic content"))
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        preferences.set(try encoder.encode(ResetAnnouncementDocument(schemaVersion:1,events:[expired,recent])),forKey:ResetReminderManager.preferencePrefix+"cache")
        let manager = ResetReminderManager(preferences:preferences,now:{ now })
        check(manager.recentMessages().map(\.id) == ["recent","history"])
        manager.dismissPanelMessage("recent")
        check(manager.panelAnnouncements(at:now).isEmpty && manager.recentMessages().count == 2,"Panel dismissal and expiry must retain history")
        manager.setMessagesEnabled(false);check(manager.recentMessages().isEmpty,"Opt out hides history")
        manager.setMessagesEnabled(true);manager.setResetMessagesEnabled(false)
        check(manager.recentMessages().isEmpty,"Category selection applies to history")
        manager.setResetMessagesEnabled(true)
        let restarted = ResetReminderManager(preferences:preferences,now:{ now.addingTimeInterval(2*86_400) })
        check(restarted.recentMessages().count == 2 && restarted.panelAnnouncements(at:now.addingTimeInterval(2*86_400)).isEmpty,"Expired cache survives without replay")
        let document = TiboChallengeDocument.initial
        check(document.phase(at:document.start.addingTimeInterval(-1)) == .upcoming)
        check(document.phase(at:document.start) == .active && document.phase(at:document.end.addingTimeInterval(-1)) == .active)
        check(document.phase(at:document.end) == .history && !document.isActive(at:document.end))
        check(ISO8601DateFormatter().string(from:document.end) == "2026-11-02T08:00:00Z","Pacific DST must apply to activity expiry")
        diagnostic("message history and activity checks passed; creating preview")
        let preview = UsagePreviewModel(now:now)
        let model = AppModel(preferences:UsagePreviewPreferences(),client:UsageClient(credentialProvider:{ nil }))
        model.useDemo();model.showResetDetails = false
        model.reminders.setActivityMessagesEnabled(false);preview.apply(UsagePreviewStyle(model))
        check(!preview.model.reminders.panelAnnouncements(at:now).isEmpty,"Reset-only selection must have a visible sample")
        model.reminders.setActivityMessagesEnabled(true)
        preview.apply(UsagePreviewStyle(model))
        var redraws = 0, messageChanges = 0
        let observation = preview.model.objectWillChange.sink { redraws += 1 }
        let messageObservation = preview.model.reminders.objectWillChange.sink { messageChanges += 1 }
        model.menuShowsPercentage.toggle()
        preview.apply(UsagePreviewStyle(model))
        check(redraws == 1 && messageChanges == 0,"Display selection must update one field without rebuilding message state")
        preview.apply(UsagePreviewStyle(model))
        check(redraws == 1 && messageChanges == 0,"Unchanged preview style must do no work")
        observation.cancel();messageObservation.cancel()
        let steady = UsagePreviewStyle(model)
        let appearanceStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            model.menuShowsPercentage.toggle();preview.apply(UsagePreviewStyle(model))
        }
        check(preview.model.menuShowsPercentage == model.menuShowsPercentage && preview.model.reminders.recentMessages().count == 1)
        preview.apply(steady)
        print(String(format:"100 appearance changes: %.1fms; display-only changes keep message state",1000*(ProcessInfo.processInfo.systemUptime-appearanceStart)))
        diagnostic("preview state checks passed; creating native window")
        model.showDailyTokenUsage = true;model.showUsageShareButton = true
        var frames: [UsagePreviewAnchor: CGRect] = [:]
        var frameRevision = 0
        let hosting = NSHostingView(rootView:SettingsView(model:model,login:LoginModel(preview:true),updates:preview.updates,previewFramesChanged:{ frames = $0;frameRevision += 1 }))
        hosting.sizingOptions = [];hosting.autoresizingMask = [.width,.height]
        let wideSize = NSSize(width:1240,height:SettingsView.height)
        let narrowSize = NSSize(width:SettingsView.minimumSize.width,height:SettingsView.height)
        let window = OverviewLayoutTestWindow(contentRect:NSRect(origin:NSPoint(x:100,y:100),size:wideSize),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = hosting;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        diagnostic("native window ordered")
        defer { window.close() }
        let tolerance:CGFloat = 1
        let controls:[UsagePreviewPart] = [.theme,.display,.messages,.resets,.chart,.sharing]
        let layoutKeys:[UsagePreviewAnchor] = [.layout(.menuControls),.layout(.menuPreview),.layout(.panelControls),.layout(.panelPreview)]
        struct DisplayState {
            let details:Bool
            let chart:Bool
            let messages:Bool
        }
        let ordinary = DisplayState(details:false,chart:true,messages:true)
        let expanded = DisplayState(details:true,chart:true,messages:true)
        func near(_ a:CGFloat,_ b:CGFloat)->Bool {a.isFinite && b.isFinite && abs(a-b)<=tolerance}
        func valid(_ rect:CGRect)->Bool {
            rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width>0 && rect.height>0
        }
        func sameGeometry(_ a:[UsagePreviewAnchor:CGRect],_ b:[UsagePreviewAnchor:CGRect])->Bool {
            guard Set(a.keys)==Set(b.keys) else {return false}
            return a.allSatisfy { key,rect in
                guard let other=b[key] else {return false}
                return near(rect.minX,other.minX) && near(rect.minY,other.minY) && near(rect.width,other.width) && near(rect.height,other.height)
            }
        }
        func overlaps(_ a:CGRect,_ b:CGRect)->Bool {
            let intersection=a.intersection(b)
            return !intersection.isNull && intersection.width>tolerance && intersection.height>tolerance
        }
        func frameText(_ rect:CGRect?)->String {
            guard let rect else {return "missing"}
            return String(format:"[x=%.2f y=%.2f w=%.2f h=%.2f]",Double(rect.minX),Double(rect.minY),Double(rect.width),Double(rect.height))
        }
        func reportGeometry(_ label:String,allAnchors:Bool = false) {
            let left=frames[.layout(.menuControls)],menu=frames[.layout(.menuPreview)]
            let right=frames[.layout(.panelControls)],panel=frames[.layout(.panelPreview)]
            let topDelta=left.flatMap {a in menu.map {a.minY-$0.minY}}
            let centerDelta=right.flatMap {a in panel.map {a.midY-$0.midY}}
            diagnostic("\(label): revision=\(frameRevision) bounds=\(frameText(hosting.bounds)) anchors=\(frames.count) leftTopDelta=\(topDelta.map {String(format:"%.2f",Double($0))} ?? "missing") rightCenterDelta=\(centerDelta.map {String(format:"%.2f",Double($0))} ?? "missing")")
            diagnostic("layout menuControls=\(frameText(left)) menuPreview=\(frameText(menu)) panelControls=\(frameText(right)) panelPreview=\(frameText(panel))")
            diagnostic("state details=\(model.showResetDetails) chart=\(model.showDailyTokenUsage) messages=\(model.reminders.messagesEnabled); targets=\(UsagePreviewPart.allCases.filter {frames[.target($0)] != nil}.map(\.rawValue).joined(separator:","))")
            if allAnchors {
                for part in UsagePreviewPart.allCases {
                    diagnostic("\(part.rawValue): control=\(frameText(frames[.control(part)])) target=\(frameText(frames[.target(part)]))")
                }
            }
        }
        func ready(_ state:DisplayState,wide:Bool,size:NSSize)->Bool {
            guard near(hosting.bounds.width,size.width),near(hosting.bounds.height,size.height),
                  layoutKeys.allSatisfy({frames[$0].map(valid) == true}),
                  controls.allSatisfy({frames[.control($0)].map(valid) == true}),
                  let left=frames[.layout(.menuControls)],let menu=frames[.layout(.menuPreview)],
                  let right=frames[.layout(.panelControls)],let panel=frames[.layout(.panelPreview)],
                  let menuTarget=frames[.target(.menu)],valid(menuTarget),
                  near(left.minY,menu.minY),
                  menu.insetBy(dx:-tolerance,dy:-tolerance).contains(menuTarget) else {return false}
            if wide {
                guard near(right.midY,panel.midY),left.maxX<=menu.minX+tolerance,right.minX>=panel.maxX-tolerance else {return false}
            } else {
                // Both control groups remain in the left column. The short
                // viewport may scroll; its content must not overlap or vanish.
                guard near(left.midX,right.midX),!overlaps(left,right),
                      max(left.maxX,right.maxX)<=min(menu.minX,panel.minX)+tolerance else {return false}
            }
            let targetStates:[(UsagePreviewPart,Bool)] = [(.resets,state.details),(.chart,state.chart),(.sharing,state.chart),(.messages,state.messages)]
            for (part,visible) in targetStates {
                if visible {
                    guard let rect=frames[.target(part)],valid(rect),panel.insetBy(dx:-tolerance,dy:-tolerance).contains(rect) else {return false}
                } else if frames[.target(part)] != nil {return false}
            }
            for (index,part) in controls.enumerated() {
                guard let rect=frames[.control(part)] else {return false}
                let group = part == .theme || part == .display ? left : right
                guard group.insetBy(dx:-tolerance,dy:-tolerance).contains(rect),!overlaps(rect,menu),!overlaps(rect,panel) else {return false}
                for other in controls.dropFirst(index+1) {
                    if let otherRect=frames[.control(other)],overlaps(rect,otherRect) {return false}
                }
            }
            return true
        }
        func awaitFrames(_ label:String,after revision:Int? = nil,_ predicate:()->Bool) async throws {
            var previous:[UsagePreviewAnchor:CGRect]?
            var stable = 0
            diagnostic("await \(label); after=\(revision.map(String.init) ?? "none") current=\(frameRevision)")
            for attempt in 1...40 {
                // Yield before checking so a previous nonempty preference
                // dictionary cannot immediately satisfy a new UI state.
                try await Task.sleep(nanoseconds:100_000_000)
                hosting.layoutSubtreeIfNeeded();hosting.displayIfNeeded()
                let fresh = revision.map {frameRevision>$0} ?? true
                if fresh && predicate() {
                    stable = previous.map {sameGeometry($0,frames)} == true ? stable+1 : 1
                    if stable>=3 {
                        reportGeometry("PASS \(label) attempt=\(attempt)")
                        return
                    }
                    previous=frames
                } else {stable=0;previous=nil}
            }
            diagnostic("FAIL await \(label); after=\(revision.map(String.init) ?? "none") fresh=\(revision.map {frameRevision>$0} ?? true) predicate=\(predicate()) stable=\(stable)")
            reportGeometry("unsettled \(label)",allAnchors:true)
            preconditionFailure("Preview did not settle for \(label); frame revision \(frameRevision)")
        }
        func verifyTargets(_ state:DisplayState) {
            let links = UsagePreviewConnections.resolve(frames)
            var expected:Set<UsagePreviewPart> = [.theme,.display]
            if state.details {expected.insert(.resets)}
            if state.messages {expected.insert(.messages)}
            if state.chart {expected.formUnion([.chart,.sharing])}
            check(Set(links.map(\.id))==expected,"Only visible targets have connectors")
            for link in links {
                let target:UsagePreviewPart = link.id == .theme || link.id == .display ? .menu : link.id
                check(frames[.control(link.id)]!.insetBy(dx:-tolerance,dy:-tolerance).contains(link.start),"\(link.id) misses its control")
                check(frames[.target(target)]!.insetBy(dx:-tolerance,dy:-tolerance).contains(link.end),"\(link.id) misses rendered target")
            }
            let menuLinks = links.filter {$0.id == .theme || $0.id == .display}
            check(menuLinks.count==2 && menuLinks[0].end==menuLinks[1].end,"Menu options address the same glyph")
        }
        func change(_ state:DisplayState,label:String,wide:Bool,size:NSSize,grows:Bool) async throws {
            let revision=frameRevision,oldHeight=frames[.layout(.panelPreview)]!.height
            diagnostic("change \(label): oldPanelHeight=\(oldHeight) expected=\(grows ? "grow" : "shrink") details=\(state.details) chart=\(state.chart) messages=\(state.messages)")
            model.showResetDetails=state.details;model.showDailyTokenUsage=state.chart
            model.reminders.setMessagesEnabled(state.messages)
            try await awaitFrames(label,after:revision) {
                guard ready(state,wide:wide,size:size),let height=frames[.layout(.panelPreview)]?.height else {return false}
                return grows ? height>oldHeight+tolerance : height<oldHeight-tolerance
            }
            verifyTargets(state)
        }
        try await awaitFrames("initial wide preview") {ready(ordinary,wide:true,size:wideSize)}
        verifyTargets(ordinary)
        let ordinaryWide=frames
        try await change(expanded,label:"wide reset details on",wide:true,size:wideSize,grows:true)
        check(Set(UsagePreviewConnections.resolve(frames).map(\.id)) == Set([.theme,.display,.messages,.resets,.chart,.sharing]),
                     "All six visible preview regions must retain their correct connectors")
        try await change(.init(details:true,chart:false,messages:true),label:"wide chart off",wide:true,size:wideSize,grows:false)
        try await change(.init(details:true,chart:false,messages:false),label:"wide messages off",wide:true,size:wideSize,grows:false)
        try await change(.init(details:false,chart:false,messages:false),label:"wide reset details off",wide:true,size:wideSize,grows:false)
        try await change(.init(details:false,chart:true,messages:false),label:"wide chart restored",wide:true,size:wideSize,grows:true)
        try await change(ordinary,label:"wide messages restored",wide:true,size:wideSize,grows:true)
        check(sameGeometry(ordinaryWide,frames),"Restoring preview contents restores wide geometry within one point")

        var revision=frameRevision;window.setContentSize(narrowSize)
        try await awaitFrames("narrow reflow",after:revision) {ready(ordinary,wide:false,size:narrowSize)}
        verifyTargets(ordinary)
        let ordinaryNarrow=frames
        try await change(expanded,label:"narrow reset details on",wide:false,size:narrowSize,grows:true)
        try await change(.init(details:true,chart:false,messages:true),label:"narrow chart off",wide:false,size:narrowSize,grows:false)
        try await change(.init(details:true,chart:false,messages:false),label:"narrow messages off",wide:false,size:narrowSize,grows:false)
        try await change(.init(details:false,chart:false,messages:false),label:"narrow reset details off",wide:false,size:narrowSize,grows:false)
        try await change(ordinary,label:"narrow contents restored",wide:false,size:narrowSize,grows:true)
        check(sameGeometry(ordinaryNarrow,frames),"Restoring preview contents restores narrow geometry within one point")

        window.setContentSize(SettingsView.minimumSize)
        // A shorter scrolling viewport can legitimately retain identical
        // content anchors. Wait for its actual bounds and stable relationships,
        // rather than demanding an unnecessary preference-change callback.
        try await awaitFrames("minimum scrolling viewport") {ready(ordinary,wide:false,size:SettingsView.minimumSize)}
        verifyTargets(ordinary)
        window.setContentSize(narrowSize)
        try await awaitFrames("narrow height restored") {ready(ordinary,wide:false,size:narrowSize) && sameGeometry(ordinaryNarrow,frames)}
        verifyTargets(ordinary)
        revision=frameRevision;window.setContentSize(wideSize)
        try await awaitFrames("wide layout restored",after:revision) {ready(ordinary,wide:true,size:wideSize) && sameGeometry(ordinaryWide,frames)}
        verifyTargets(ordinary)
        revision=frameRevision;window.setContentSize(narrowSize)
        try await awaitFrames("narrow layout restored again",after:revision) {ready(ordinary,wide:false,size:narrowSize) && sameGeometry(ordinaryNarrow,frames)}
        verifyTargets(ordinary)
        check(model.reminders.enabled == false,"Preview must not enable notifications")
        print("Overview checks passed: four actual layout anchors, wide alignment, narrow reflow, changing preview heights, stable restoration and six connectors")
    }
}
