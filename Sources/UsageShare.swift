import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct UsageShareImage {
    let image: NSImage
    let png: Data
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([image]) && pasteboard.setData(png,forType:.png)
    }
    func save(to url: URL) throws { try png.write(to:url,options:.atomic) }
    @MainActor func activityItem(filename:String) -> NSPreviewRepresentingActivityItem {
        let provider = NSItemProvider(item:png as NSData,typeIdentifier:UTType.png.identifier)
        provider.suggestedName = filename
        // Supply explicit share-sheet metadata; an unannotated provider can
        // otherwise receive the system's generic source icon as its preview.
        return NSPreviewRepresentingActivityItem(item:provider,title:L("每日 Token 使用量", "Daily Token usage"),image:image,icon:image)
    }
}

@MainActor enum UsageImageExporter {
    static func render(statistics:UsageStatistics,days:Int,now:Date,dark:Bool,logo:NSImage? = nil) -> UsageShareImage? {
        let view = VStack(spacing:16) {
            DailyUsageChart(statistics:statistics,refreshing:false,now:now,days:.constant(days),exporting:true,
                exportLogo:logo ?? BuddyBrand.shareLogo(dark:dark))
            UsageStatisticsRow(statistics:statistics)
        }.padding(20).frame(width:380)
            .background(dark ? Color(white:0.1) : .white)
            .environment(\.colorScheme,dark ? .dark : .light)
        let renderer = ImageRenderer(content:view)
        renderer.scale = 2;renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width:380,height:nil)
        guard let cgImage = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,cgImage,nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let image = NSImage(cgImage:cgImage,size:NSSize(width:CGFloat(cgImage.width)/2,height:CGFloat(cgImage.height)/2))
        guard let png = removingTextMetadata(data as Data) else { return nil }
        return UsageShareImage(image:image,png:png)
    }
    private static func removingTextMetadata(_ data:Data) -> Data? {
        guard data.count >= 8 else { return nil }
        var clean = Data(data.prefix(8)),offset = 8
        while offset+12 <= data.count {
            let count = data[offset..<offset+4].reduce(0) { ($0<<8)|Int($1) }
            let end = offset+count+12
            guard end <= data.count else { return nil }
            let type = String(data:data[offset+4..<offset+8],encoding:.ascii)
            if !["eXIf","tEXt","zTXt","iTXt"].contains(type) { clean.append(data[offset..<end]) }
            offset = end
        }
        return offset == data.count ? clean : nil
    }
    static func filename(now:Date,days:Int) -> String {
        let formatter = DateFormatter();formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.calendar = Calendar(identifier:.gregorian);formatter.timeZone = .autoupdatingCurrent;formatter.dateFormat = "yyyy-MM-dd"
        return "Codex-Buddy-usage-\(formatter.string(from:now))-\(days)d.png"
    }
}

struct UsageShareButton: NSViewRepresentable {
    var statistics: UsageStatistics?
    var days: Int
    var now: Date
    var dark: Bool
    var presentationChanged: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSButton {
        let button = NSButton(image:NSImage(systemSymbolName:"square.and.arrow.up",accessibilityDescription:L("分享用量图片", "Share usage image"))!,target:context.coordinator,action:#selector(Coordinator.share(_:)))
        button.isBordered = false;button.imagePosition = .imageOnly
        // AppKit's sharing picker expects presentation from mouseDown.
        button.sendAction(on:.leftMouseDown)
        button.toolTip = L("分享、保存或复制用量图片", "Share, save, or copy usage image")
        button.setAccessibilityLabel(L("分享用量图片", "Share usage image"))
        context.coordinator.button = button
        return button
    }
    func updateNSView(_ button:NSButton,context:Context) {
        context.coordinator.parent = self
        button.isEnabled = statistics != nil
    }
    @MainActor final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var parent: UsageShareButton
        weak var button: NSButton?
        private var picker: NSSharingServicePicker?
        private var payload: UsageShareImage?
        private var exportFilename = ""
        private var saveService: NSSharingService?
        private var copyService: NSSharingService?
        private var presenting = false
        init(_ parent:UsageShareButton) { self.parent = parent }
        @objc func share(_ button:NSButton) {
            guard !presenting,let statistics = parent.statistics else { return }
            guard let payload = UsageImageExporter.render(statistics:statistics,days:parent.days,now:parent.now,dark:parent.dark) else {
                showError(L("无法生成用量图片，请稍后重试。", "Could not create the usage image. Please try again."));return
            }
            self.payload = payload;exportFilename = UsageImageExporter.filename(now:parent.now,days:parent.days)
            presenting = true;parent.presentationChanged(true)
            let preview = payload.activityItem(filename:exportFilename)
            let picker = NSSharingServicePicker(items:[preview]);picker.delegate = self;self.picker = picker
            picker.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        }
        func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,sharingServicesForItems items:[Any],proposedSharingServices:[NSSharingService]) -> [NSSharingService] {
            if saveService == nil || copyService == nil,let payload {
                let filename = exportFilename
                saveService = NSSharingService(title:L("保存图片…", "Save image…"),image:NSImage(systemSymbolName:"square.and.arrow.down",accessibilityDescription:nil)!,alternateImage:nil) { [weak self] in
                    DispatchQueue.main.async { self?.save(payload,filename:filename) }
                }
                copyService = NSSharingService(title:L("复制图片", "Copy image"),image:NSImage(systemSymbolName:"doc.on.doc",accessibilityDescription:nil)!,alternateImage:nil) { [weak self] in
                    guard let self else { return }
                    if !payload.copy() { self.showError(L("无法复制图片，请重试。", "Could not copy the image. Please try again.")) }
                    else { self.finish() }
                }
            }
            // Keep one explicit image-copy action in the native service list.
            let copyTitles: Set<String> = ["Copy","拷贝","复制","拷貝","複製"]
            return [saveService,copyService].compactMap { $0 }+proposedSharingServices.filter { !copyTitles.contains($0.title) }
        }
        func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,delegateFor sharingService:NSSharingService) -> NSSharingServiceDelegate? {
            sharingService === saveService || sharingService === copyService ? nil : self
        }
        func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,didChoose service:NSSharingService?) {
            if service == nil { finish() }
        }
        func sharingService(_ sharingService:NSSharingService,didShareItems items:[Any]) { finish() }
        func sharingService(_ sharingService:NSSharingService,didFailToShareItems items:[Any],error:Error) { finish() }
        private func save(_ payload:UsageShareImage,filename:String) {
            presenting = true;parent.presentationChanged(true)
            let panel = NSSavePanel();panel.allowedContentTypes = [.png];panel.canCreateDirectories = true
            panel.nameFieldStringValue = filename
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                if response == .OK,let url = panel.url {
                    do { try payload.save(to:url) }
                    catch { self.showError(L("无法保存图片，请选择其他位置重试。", "Could not save the image. Please try another location."));return }
                }
                self.finish()
            }
            if let window = button?.window,window.isVisible { panel.beginSheetModal(for:window,completionHandler:completion) }
            else { panel.begin(completionHandler:completion) }
        }
        private func showError(_ message:String) {
            presenting = true;parent.presentationChanged(true)
            let alert = NSAlert();alert.messageText = message;alert.addButton(withTitle:L("好", "OK"))
            if let window = button?.window { alert.beginSheetModal(for:window) { [weak self] _ in self?.finish() } }
            else { alert.runModal();finish() }
        }
        private func finish() {
            guard presenting else { return }
            presenting = false;parent.presentationChanged(false)
            picker = nil;payload = nil;saveService = nil;copyService = nil
        }
    }
}
