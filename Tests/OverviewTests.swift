import AppKit
import SwiftUI
import Combine

@main struct OverviewTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.regular)
        precondition(SettingsView.preferredHeight(for:.overview) == 1040 && SettingsView.preferredHeight(for:.general) == 620)
        precondition(SettingsView.fittedHeight(for:.overview,availableHeight:800) == 720,"Default must fit the available screen")
        precondition(SettingsView.fittedHeight(for:.overview,availableHeight:1440) == 1040,"Large screens retain tall preview space")
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
        precondition(manager.recentMessages().map(\.id) == ["recent","history"])
        manager.dismissPanelMessage("recent")
        precondition(manager.panelAnnouncements(at:now).isEmpty && manager.recentMessages().count == 2,"Panel dismissal and expiry must retain history")
        manager.setMessagesEnabled(false);precondition(manager.recentMessages().isEmpty,"Opt out hides history")
        manager.setMessagesEnabled(true);manager.setResetMessagesEnabled(false)
        precondition(manager.recentMessages().isEmpty,"Category selection applies to history")
        manager.setResetMessagesEnabled(true)
        let restarted = ResetReminderManager(preferences:preferences,now:{ now.addingTimeInterval(2*86_400) })
        precondition(restarted.recentMessages().count == 2 && restarted.panelAnnouncements(at:now.addingTimeInterval(2*86_400)).isEmpty,"Expired cache survives without replay")
        let document = TiboChallengeDocument.initial
        precondition(document.phase(at:document.start.addingTimeInterval(-1)) == .upcoming)
        precondition(document.phase(at:document.start) == .active && document.phase(at:document.end.addingTimeInterval(-1)) == .active)
        precondition(document.phase(at:document.end) == .history && !document.isActive(at:document.end))
        precondition(ISO8601DateFormatter().string(from:document.end) == "2026-11-02T08:00:00Z","Pacific DST must apply to activity expiry")
        let preview = UsagePreviewModel(now:now)
        let model = AppModel(preferences:UsagePreviewPreferences(),client:UsageClient(credentialProvider:{ nil }))
        model.useDemo();model.showResetDetails = false
        model.reminders.setActivityMessagesEnabled(false);preview.apply(UsagePreviewStyle(model))
        precondition(!preview.model.reminders.panelAnnouncements(at:now).isEmpty,"Reset-only selection must have a visible sample")
        model.reminders.setActivityMessagesEnabled(true)
        preview.apply(UsagePreviewStyle(model))
        var redraws = 0, messageChanges = 0
        let observation = preview.model.objectWillChange.sink { redraws += 1 }
        let messageObservation = preview.model.reminders.objectWillChange.sink { messageChanges += 1 }
        model.menuShowsPercentage.toggle()
        preview.apply(UsagePreviewStyle(model))
        precondition(redraws == 1 && messageChanges == 0,"Display selection must update one field without rebuilding message state")
        preview.apply(UsagePreviewStyle(model))
        precondition(redraws == 1 && messageChanges == 0,"Unchanged preview style must do no work")
        observation.cancel();messageObservation.cancel()
        let steady = UsagePreviewStyle(model)
        let appearanceStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            model.menuShowsPercentage.toggle();preview.apply(UsagePreviewStyle(model))
        }
        precondition(preview.model.menuShowsPercentage == model.menuShowsPercentage && preview.model.reminders.recentMessages().count == 1)
        preview.apply(steady)
        print(String(format:"100 appearance changes: %.1fms; display-only changes keep message state",1000*(ProcessInfo.processInfo.systemUptime-appearanceStart)))
        var frames: [UsagePreviewAnchor: CGRect] = [:]
        let hosting = NSHostingView(rootView:SettingsView(model:model,login:LoginModel(preview:true),updates:preview.updates,previewFramesChanged:{ frames = $0 }))
        hosting.sizingOptions = [];hosting.autoresizingMask = [.width,.height]
        let window = NSWindow(contentRect:NSRect(x:100,y:100,width:1240,height:SettingsView.height),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = hosting;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        defer { window.close() }
        func awaitFrames(_ predicate: () -> Bool) async throws {
            for _ in 0..<40 {
                hosting.layoutSubtreeIfNeeded()
                if predicate() { return }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            preconditionFailure("Preview failed to settle at its rendered anchors")
        }
        try await awaitFrames { frames[.target(.chart)] != nil && frames[.target(.messages)] != nil }
        func verifyTargets() {
            let links = UsagePreviewConnections.resolve(frames)
            for link in links {
                let target: UsagePreviewPart = link.id == .theme || link.id == .display ? .menu : link.id
                precondition(frames[.target(target)]!.insetBy(dx:-1,dy:-1).contains(link.end),"\(link.id) misses rendered target")
            }
            let menuLinks = links.filter { $0.id == .theme || $0.id == .display }
            precondition(menuLinks.count == 2 && menuLinks[0].end == menuLinks[1].end,"Menu options address the same glyph")
        }
        verifyTargets();precondition(!UsagePreviewConnections.resolve(frames).contains { $0.id == .resets },"Hidden details have no connector")
        model.showResetDetails = true;try await awaitFrames { frames[.target(.resets)] != nil };verifyTargets()
        precondition(Set(UsagePreviewConnections.resolve(frames).map(\.id)) == Set([.theme,.display,.messages,.resets,.chart,.sharing]),
                     "All six visible preview regions must retain their correct connectors")
        let originalMenu = frames[.target(.menu)]!;window.setContentSize(SettingsView.minimumSize)
        try await awaitFrames { frames[.target(.menu)] != originalMenu };verifyTargets()
        model.showDailyTokenUsage = false
        try await awaitFrames { frames[.target(.chart)] == nil && frames[.target(.sharing)] == nil }
        precondition(!UsagePreviewConnections.resolve(frames).contains { $0.id == .chart || $0.id == .sharing })
        model.reminders.setMessagesEnabled(false);try await awaitFrames { frames[.target(.messages)] == nil }
        model.showDailyTokenUsage = true;model.reminders.setMessagesEnabled(true);model.showResetDetails = false
        try await awaitFrames { frames[.target(.chart)] != nil && frames[.target(.messages)] != nil && frames[.target(.resets)] == nil };verifyTargets()
        precondition(model.reminders.enabled == false,"Preview must not enable notifications")
        print("Overview checks passed: history, reception/category gates, Pacific expiry, native anchors, toggles and narrow-window layout")
    }
}
