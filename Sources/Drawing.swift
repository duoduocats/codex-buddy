import AppKit
import SwiftUI

enum DuoDrawing {
    static func silhouette() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 582, y: 252))
        p.curve(to: .init(x: 325,y: 322), controlPoint1: .init(x: 495,y: 172), controlPoint2: .init(x: 351,y: 202))
        p.curve(to: .init(x: 253,y: 582), controlPoint1: .init(x: 205,y: 348), controlPoint2: .init(x: 165,y: 488))
        p.curve(to: .init(x: 443,y: 773), controlPoint1: .init(x: 220,y: 712), controlPoint2: .init(x: 328,y: 794))
        p.curve(to: .init(x: 700,y: 730), controlPoint1: .init(x: 528,y: 862), controlPoint2: .init(x: 670,y: 804))
        p.curve(to: .init(x: 770,y: 443), controlPoint1: .init(x: 821,y: 705), controlPoint2: .init(x: 858,y: 541))
        p.curve(to: .init(x: 582,y: 252), controlPoint1: .init(x: 810,y: 321), controlPoint2: .init(x: 707,y: 226))
        p.close(); return p
    }
    static func image(size: NSSize, window: LimitWindow?, credits: Int?, now: Date, menu: Bool, stale: Bool = false, dark: Bool = false, menuShowsPercentage: Bool = false, menuTheme: MenuBarTheme = .ring) -> NSImage {
        let result = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            let cat = menu && menuTheme == .duoDuoCat
            let layout = MenuIconLayout.inRect(rect,theme:menuTheme)
            let s = menu ? layout.scale : min(rect.width / 248, rect.height / 258)
            ctx.translateBy(x: menu ? layout.origin.x : rect.midX, y: menu ? layout.origin.y : rect.midY+10*s)
            ctx.scaleBy(x: s, y: s)
            let ink = dark ? NSColor.white : NSColor.black
            ink.setStroke(); ink.setFill()
            // Keep both colors on one silhouette; avoid independent pixel rounding.
            let strokeWidth: CGFloat = cat ? DuoDuoCatGeometry.strokeWidth : menu ? 17 : 15
            let fraction = max(0,min(1,(window?.remaining ?? 0) / 100))
            // Opaque mid-gray keeps the detail ring visible over bright glass backdrops.
            let gray = menu
                ? NSColor(white:dark ? 145.0/255 : 140.0/255,alpha:1)
                : NSColor(white:128.0/255,alpha:1)
            // Clip a single rounded silhouette, then divide its colors with a radial
            // straight edge. A tiny remainder must never become a full circular cap.
            let ring: CGPath
            if cat { ring = DuoDuoCatGeometry.silhouette }
            else if menu { ring = MenuIconLayout.ringSilhouette }
            else {
                let outline = CGMutablePath()
                outline.addArc(center:.zero,radius:100,startAngle:150 * .pi / 180,endAngle:390 * .pi / 180,clockwise:false)
                ring = outline.copy(strokingWithWidth:strokeWidth,lineCap:.round,lineJoin:.round,miterLimit:10)
            }
            ctx.saveGState()
            ctx.addPath(ring);ctx.clip()
            gray.setFill();NSRect(x:-120,y:-120,width:240,height:240).fill()
            ink.setFill()
            if fraction >= 1 {
                NSRect(x:-120,y:-120,width:240,height:240).fill()
            } else if fraction > 0 {
                let sector = CGMutablePath()
                sector.move(to:.zero)
                let start: CGFloat = cat ? DuoDuoCatGeometry.leftAngle : 150 * .pi / 180
                let sweep: CGFloat = cat ? 2 * .pi + DuoDuoCatGeometry.capAngle - start : 240 * .pi / 180
                sector.addArc(center:.zero,radius:200,startAngle:start - 10 * .pi / 180,endAngle:start + sweep * CGFloat(fraction),clockwise:false)
                sector.closeSubpath()
                ctx.addPath(sector);ctx.fillPath()
            }
            ctx.restoreGState()
            ink.setStroke();ink.setFill()
            let dots = cat ? DuoDuoCatGeometry.resetDots : MenuIconLayout.ringDots
            for (index, point) in dots.enumerated() {
                // Preserve subpixel centers and common radii in the 2x raster.
                let radius: CGFloat = cat ? DuoDuoCatGeometry.dotDiameter / 2 : menu ? 12 : 10.5
                let dot = NSBezierPath(ovalIn:NSRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2))
                if let credits, index < credits { dot.fill() }
                else { gray.setFill();dot.fill();ink.setFill() }
            }
            let title = menu && menuShowsPercentage
                ? window.map { String(format:"%.0f%%",$0.remaining) } ?? "—"
                : (menu ? window?.countdown(now:now) : window?.detailCountdown(now:now)) ?? "—"
            let fontSize: CGFloat = menu
                ? (menuShowsPercentage ? (title.count > 3 ? 48 : 58) : cat ? 76 : title.count > 3 ? 65 : 80)
                : 42
            let font = menu
                ? NSFont.monospacedDigitSystemFont(ofSize:fontSize,weight:.semibold)
                : NSFont.systemFont(ofSize:fontSize,weight:.medium)
            let text = NSMutableAttributedString(string:title,attributes:[.font:font,.foregroundColor:ink])
            if !menu || menuShowsPercentage {
                let ratio = min(1,132 / text.size().width)
                if ratio < 1 {
                    let fitted = menu ? NSFont.monospacedDigitSystemFont(ofSize:fontSize*ratio,weight:.semibold) : NSFont.systemFont(ofSize:fontSize*ratio,weight:.medium)
                    text.addAttribute(.font,value:fitted,range:NSRange(location:0,length:text.length))
                }
            }
            let textSize = text.size()
            if menu {
                text.draw(at:.init(x:-textSize.width/2,y:-textSize.height/2+(cat ? -7 : 2)))
            }
            if !menu {
                let badgeHeight: CGFloat = 42
                let gap: CGFloat = 12
                // Center the badge and countdown together within the ring.
                let groupTop = -(badgeHeight + gap + textSize.height) / 2
                text.draw(at:.init(x:-textSize.width/2,y:groupTop+badgeHeight+gap))
                BuddyBrand.head(dark:dark)?.draw(in:NSRect(x:-26.5,y:groupTop,width:53,height:badgeHeight),
                    from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            }
            if stale {
                let p = NSBezierPath(ovalIn:NSRect(x:108,y:-3,width:10,height:10));ink.setFill();p.fill()
            }
            ctx.restoreGState(); return true
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width*2),pixelsHigh:Int(size.height*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        result.draw(in:NSRect(origin:.zero,size:size))
        NSGraphicsContext.restoreGraphicsState()
        let cached = NSImage(size:size);cached.addRepresentation(bitmap);cached.isTemplate=false
        return cached
    }
}

struct DuoIcon: View {
    @ObservedObject var model: AppModel
    var compact = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let width: CGFloat = compact ? 154 : 210
        let height: CGFloat = compact ? 160 : 218
        Image(nsImage:DuoDrawing.image(size:.init(width:width,height:height),window:model.window,credits:model.credits,now:model.now,menu:false,dark:scheme == .dark))
            .frame(width:width,height:height)
            .accessibilityLabel(L("下次重置 \(model.window?.detailCountdown(now:model.now) ?? "—")，剩余重置次数 \(model.credits.map(String.init) ?? "—")", "Resets in \(model.window?.detailCountdown(now:model.now) ?? "—"), \(model.credits.map(String.init) ?? "—") reset credits available"))
    }
}
