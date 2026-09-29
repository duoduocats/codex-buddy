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
    static func image(size: NSSize, window: LimitWindow?, credits: Int?, now: Date, menu: Bool, stale: Bool = false, dark: Bool = false) -> NSImage {
        let result = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            let s = menu ? min(rect.width / 220, rect.height / 220) : min(rect.width / 248, rect.height / 258)
            ctx.translateBy(x: rect.midX, y: rect.midY + (menu ? -1.5 : 10) * s)
            ctx.scaleBy(x: s, y: s)
            let ink = dark ? NSColor.white : NSColor.black
            ink.setStroke(); ink.setFill()
            // Keep both colors on one silhouette; avoid independent pixel rounding.
            let strokeWidth: CGFloat = menu ? 17 : 15
            let fraction = max(0,min(1,(window?.remaining ?? 0) / 100))
            // Opaque mid-gray keeps the detail ring visible over bright glass backdrops.
            let gray = menu
                ? NSColor(white:dark ? 145.0/255 : 140.0/255,alpha:1)
                : NSColor(white:128.0/255,alpha:1)
            // Clip a single rounded silhouette, then divide its colors with a radial
            // straight edge. A tiny remainder must never become a full circular cap.
            let outline = CGMutablePath()
            outline.addArc(center:.zero,radius:100,startAngle:150 * .pi / 180,endAngle:390 * .pi / 180,clockwise:false)
            let ring = outline.copy(strokingWithWidth:strokeWidth,lineCap:.round,lineJoin:.round,miterLimit:10)
            ctx.saveGState()
            ctx.addPath(ring);ctx.clip()
            gray.setFill();NSRect(x:-120,y:-120,width:240,height:240).fill()
            ink.setFill()
            if fraction >= 1 {
                NSRect(x:-120,y:-120,width:240,height:240).fill()
            } else if fraction > 0 {
                let sector = CGMutablePath()
                sector.move(to:.zero)
                sector.addArc(center:.zero,radius:200,startAngle:140 * .pi / 180,endAngle:(150+240*fraction) * .pi / 180,clockwise:false)
                sector.closeSubpath()
                ctx.addPath(sector);ctx.fillPath()
            }
            ctx.restoreGState()
            ink.setStroke();ink.setFill()
            for (index, degrees) in [126.0,102.0,78.0,54.0].enumerated() {
                let angle = degrees * Double.pi / 180
                // Equal angular steps give equal chord gaps. Keeping subpixel centers
                // and equal radii preserves mirror symmetry in the 2x raster.
                let point = CGPoint(x:cos(angle)*100,y:sin(angle)*100)
                let radius: CGFloat = menu ? 12 : 10.5
                let dot = NSBezierPath(ovalIn:NSRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2))
                if let credits, index < credits { dot.fill() }
                else { gray.setFill();dot.fill();ink.setFill() }
            }
            let title = (menu ? window?.countdown(now:now) : window?.detailCountdown(now:now)) ?? "—"
            let fontSize: CGFloat = menu ? (title.count > 3 ? 65 : 80) : 42
            let font = menu
                ? NSFont.monospacedDigitSystemFont(ofSize:fontSize,weight:.semibold)
                : NSFont.systemFont(ofSize:fontSize,weight:.medium)
            let text = NSMutableAttributedString(string:title,attributes:[.font:font,.foregroundColor:ink])
            if !menu {
                let ratio = min(1,132 / text.size().width)
                if ratio < 1 {
                    text.addAttribute(.font,value:NSFont.systemFont(ofSize:fontSize*ratio,weight:.medium),range:NSRange(location:0,length:text.length))
                }
            }
            let textSize = text.size()
            if menu {
                text.draw(at:.init(x:-textSize.width/2,y:-textSize.height/2+2))
            }
            if !menu {
                let badge = silhouette()
                let badgeScale: CGFloat = 0.075
                let badgeHeight = badge.bounds.height * badgeScale
                let gap: CGFloat = 12
                // Center the badge and countdown together within the ring.
                let groupTop = -(badgeHeight + gap + textSize.height) / 2
                text.draw(at:.init(x:-textSize.width/2,y:groupTop+badgeHeight+gap))
                let badgeY = groupTop - (badge.bounds.minY-512)*badgeScale
                ctx.saveGState()
                ctx.translateBy(x:0,y:badgeY);ctx.scaleBy(x:badgeScale,y:badgeScale);ctx.translateBy(x:-512,y:-512)
                NSColor(calibratedRed:0.36,green:0.30,blue:1,alpha:1).setFill();badge.fill()
                NSColor.white.setStroke()
                let glyph=NSBezierPath();glyph.move(to:.init(x:374,y:431));glyph.line(to:.init(x:418,y:516));glyph.line(to:.init(x:374,y:598));glyph.move(to:.init(x:533,y:600));glyph.line(to:.init(x:650,y:600))
                glyph.lineWidth=48;glyph.lineCapStyle = .round;glyph.lineJoinStyle = .round;glyph.stroke()
                ctx.restoreGState()
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
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(nsImage:DuoDrawing.image(size:.init(width:210,height:218),window:model.window,credits:model.credits,now:model.now,menu:false,dark:scheme == .dark))
            .frame(width:210,height:218)
            .accessibilityLabel(L("下次重置 \(model.window?.detailCountdown(now:model.now) ?? "—")，剩余重置次数 \(model.credits.map(String.init) ?? "—")", "Resets in \(model.window?.detailCountdown(now:model.now) ?? "—"), \(model.credits.map(String.init) ?? "—") reset credits available"))
    }
}
