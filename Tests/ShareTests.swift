import AppKit
import ImageIO

@main struct ShareTests {
    static func check(_ condition:Bool,_ message:String) {
        guard condition else { fputs(message+"\n",stderr);exit(1) }
    }
    static func checkTooltipPlacement() {
        let chart = CGRect(x:0,y:0,width:340,height:112)
        let narrowPlot = CGRect(x:0,y:0,width:118,height:112)
        let shiftedChart = CGRect(x:40,y:20,width:340,height:112)
        let cases:[(String,CGSize,CGPoint,CGRect,CGRect)] = [
            ("left endpoint",CGSize(width:132,height:44),CGPoint(x:0,y:24),chart,CGRect(x:4,y:24,width:132,height:44)),
            ("near left edge",CGSize(width:132,height:44),CGPoint(x:12,y:24),chart,CGRect(x:4,y:24,width:132,height:44)),
            ("middle",CGSize(width:132,height:44),CGPoint(x:170,y:24),chart,CGRect(x:104,y:24,width:132,height:44)),
            ("near right edge",CGSize(width:132,height:44),CGPoint(x:328,y:24),chart,CGRect(x:204,y:24,width:132,height:44)),
            ("right endpoint",CGSize(width:132,height:44),CGPoint(x:340,y:24),chart,CGRect(x:204,y:24,width:132,height:44)),
            ("top edge",CGSize(width:132,height:44),CGPoint(x:170,y:0),chart,CGRect(x:104,y:4,width:132,height:44)),
            ("bottom edge",CGSize(width:132,height:44),CGPoint(x:170,y:112),chart,CGRect(x:104,y:64,width:132,height:44)),
            ("large fitting content",CGSize(width:280,height:96),CGPoint(x:170,y:12),chart,CGRect(x:30,y:12,width:280,height:96)),
            ("large content near corner",CGSize(width:280,height:96),CGPoint(x:326,y:100),chart,CGRect(x:56,y:12,width:280,height:96)),
            ("oversize content",CGSize(width:500,height:150),CGPoint(x:170,y:24),chart,CGRect(x:4,y:4,width:332,height:104)),
            ("narrow plot center",CGSize(width:90,height:48),CGPoint(x:59,y:28),narrowPlot,CGRect(x:14,y:28,width:90,height:48)),
            ("narrow plot corner",CGSize(width:90,height:48),CGPoint(x:112,y:100),narrowPlot,CGRect(x:24,y:60,width:90,height:48)),
            ("narrow plot oversize width",CGSize(width:160,height:48),CGPoint(x:59,y:28),narrowPlot,CGRect(x:4,y:28,width:110,height:48)),
            ("shifted chart center",CGSize(width:132,height:44),CGPoint(x:210,y:42),shiftedChart,CGRect(x:144,y:42,width:132,height:44)),
            ("shifted chart top left",CGSize(width:132,height:44),CGPoint(x:43,y:16),shiftedChart,CGRect(x:44,y:24,width:132,height:44)),
            ("shifted chart bottom right",CGSize(width:132,height:44),CGPoint(x:379,y:131),shiftedChart,CGRect(x:244,y:84,width:132,height:44))
        ]
        for (label,size,anchor,bounds,expected) in cases {
            let frame = UsageTooltipPlacement.frame(contentSize:size,anchor:anchor,bounds:bounds)
            let inset = bounds.insetBy(dx:4,dy:4)
            check(frame.minX >= inset.minX && frame.maxX <= inset.maxX &&
                  frame.minY >= inset.minY && frame.maxY <= inset.maxY,
                  "\(label): the full tooltip frame must stay inside the chart padding")
            check(frame == expected,"\(label): tooltip must preserve centered placement when it fits and clamp at edges; got \(frame), expected \(expected)")
        }
        print("Native tooltip placement tests passed: chart endpoints, near edges, center, vertical bounds, large content, narrow plots, shifted bounds")
    }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = .autoupdatingCurrent
        let now = calendar.date(from:DateComponents(year:2026,month:9,day:30,hour:12))!
        let statistics = UsageStatistics.demo(now:now)
        guard CommandLine.arguments.count > 1,
              let icon = NSImage(contentsOfFile:CommandLine.arguments[1]),
              let mascot = BuddyBrand.transparentMascot(from:icon) else { fatalError("Public app icon fixture is required") }
        guard CommandLine.arguments.count > 2,
              let canonical = NSImage(contentsOfFile:CommandLine.arguments[2]),
              let renderedCanonical = BuddyBrand.canonicalMark(from:canonical),
              let expectedCG = mascot.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let actualCG = renderedCanonical.cgImage(forProposedRect:nil,context:nil,hints:nil) else { fatalError("Canonical brand fixture is required") }
        check(expectedCG.width == actualCG.width && expectedCG.height == actualCG.height,"The independent mark must preserve canonical dimensions")
        let expectedPixels=NSBitmapImageRep(cgImage:expectedCG),actualPixels=NSBitmapImageRep(cgImage:actualCG)
        for y in 0..<expectedCG.height { for x in 0..<expectedCG.width {
            let expected=expectedPixels.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            let actual=actualPixels.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            check(abs(expected.alphaComponent-actual.alphaComponent) < 0.005,"The independent mark must preserve the original silhouette and cutouts")
            if expected.alphaComponent > 0.1 {
                check(abs(expected.redComponent-actual.redComponent) < 0.01 && abs(expected.greenComponent-actual.greenComponent) < 0.01 && abs(expected.blueComponent-actual.blueComponent) < 0.01,"Settings and sharing colors must remain unchanged")
            }
        } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-share-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        for days in [7,14,30] {
            for dark in [false,true] {
                guard let logo = BuddyBrand.logo(fromMascot:mascot,dark:dark),
                      let logoCG = logo.cgImage(forProposedRect:nil,context:nil,hints:nil),
                      let payload = UsageImageExporter.render(statistics:statistics,days:days,now:now,dark:dark,logo:logo),
                      let bitmap = NSBitmapImageRep(data:payload.png) else { fatalError("Native usage export must render a valid PNG") }
                fputs("Export \(days)d \(dark ? "dark" : "light"): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh) pixels\n",stderr)
                check(bitmap.pixelsWide == 760 && bitmap.pixelsHigh >= 400 && bitmap.pixelsHigh < 700,
                             "Export must contain the graphic logo, chart and five metrics at 2x density")
                let ratio = Double(logoCG.width)/Double(logoCG.height)
                check((1.2...1.6).contains(ratio),"Logo must keep the app's head proportions without the row of four feet")
                let logoBitmap = NSBitmapImageRep(cgImage:logoCG)
                var transparent = 0
                for y in 0..<logoCG.height {
                    var rowHasInk = false
                    for x in 0..<logoCG.width {
                        let alpha = logoBitmap.colorAt(x:x,y:y)!.alphaComponent
                        if alpha > 0 { rowHasInk = true } else { transparent += 1 }
                    }
                    check(rowHasInk,"A head-only logo must not contain a detached row of feet below an empty gap")
                }
                check(transparent > 100,"Logo must retain its transparent background and terminal cutouts")
                var offset = 8
                while offset+12 <= payload.png.count {
                    let size = payload.png[offset..<offset+4].reduce(0) { ($0<<8)|Int($1) }
                    let type = String(data:payload.png[offset+4..<offset+8],encoding:.ascii)!
                    check(!["eXIf","tEXt","zTXt","iTXt"].contains(type),"Export must not include text or EXIF metadata")
                    offset += size+12
                }
                let filename = UsageImageExporter.filename(now:now,days:days)
                check(filename == "Codex-Buddy-usage-2026-09-30-\(days)d.png","Export filename must use the selected date range")
                let preview = payload.activityItem(filename:filename)
                check(preview.imageProvider != nil,"The native share sheet must receive an explicit image thumbnail")
                check((preview.item as? NSItemProvider)?.suggestedName == filename,
                      "The shared PNG must retain a safe suggested filename")
                let url = directory.appendingPathComponent(filename)
                try payload.save(to:url)
                let saved = try Data(contentsOf:url)
                check(saved == payload.png,"Saved PNG must equal the generated image")
                let board = NSPasteboard.withUniqueName()
                check(payload.copy(to:board),"Image must copy to an isolated test pasteboard")
                check(board.data(forType:.png) == payload.png && board.canReadObject(forClasses:[NSImage.self],options:nil),
                             "Copy must support both PNG bytes and native image pasting")
                board.releaseGlobally()
            }
        }
        print("Native sharing tests passed: 7/14/30-day images, light/dark, PNG dimensions and metadata, atomic save, isolated clipboard")
        checkTooltipPlacement()
    }
}
