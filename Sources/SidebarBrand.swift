import AppKit
import SwiftUI

struct SidebarBrand: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SidebarBrandDrawing(dark:colorScheme == .dark).frame(width:110,height:42)
            .accessibilityElement(children:.ignore).accessibilityLabel("CodexBuddy")
            .accessibilityIdentifier("buddy-sidebar-brand")
    }
}

struct SidebarBrandPlacement {
    let head: CGRect
    let wordmark: CGRect

    init(in bounds:CGRect,headSize:CGSize) {
        let scale = min(bounds.width/110,bounds.height/42)
        let headScale = min(42/headSize.width,34/headSize.height)*scale
        let headWidth = headSize.width*headScale,headHeight = headSize.height*headScale
        let artwork = SidebarWordmarkArtwork.bounds
        let typeScale = min(61/artwork.width,38/artwork.height)*scale
        let typeWidth = artwork.width*typeScale,typeHeight = artwork.height*typeScale
        let left = bounds.midX-(headWidth+7*scale+typeWidth)/2
        head = CGRect(x:left,y:bounds.midY-headHeight/2,width:headWidth,height:headHeight)
        wordmark = CGRect(x:head.maxX+7*scale,y:bounds.midY-typeHeight/2,width:typeWidth,height:typeHeight)
    }
}

private struct SidebarBrandDrawing: NSViewRepresentable {
    let dark: Bool
    func makeNSView(context:Context) -> SidebarBrandDrawingView { SidebarBrandDrawingView() }
    func updateNSView(_ view:SidebarBrandDrawingView,context:Context) {
        guard view.dark != dark else { return }
        view.dark = dark;view.needsDisplay = true
    }
}

private final class SidebarBrandDrawingView: NSView {
    var dark = false

    override func draw(_ dirtyRect:NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let head = BuddyBrand.sidebarHeadGlyph?.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return }
        let placement = SidebarBrandPlacement(in:bounds,headSize:CGSize(width:head.width,height:head.height))
        let neutral = (dark ? NSColor.white : NSColor.black).cgColor
        context.saveGState()
        context.clip(to:placement.head,mask:head)
        context.setFillColor(neutral);context.fill(placement.head)
        context.restoreGState()

        let artwork = SidebarWordmarkArtwork.bounds
        let scale = placement.wordmark.width/artwork.width
        context.saveGState()
        context.translateBy(x:placement.wordmark.minX,y:placement.wordmark.minY)
        context.scaleBy(x:scale,y:scale)
        context.translateBy(x:-artwork.minX,y:-artwork.minY)
        context.setFillColor(neutral)
        context.addPath(SidebarWordmarkArtwork.letters);context.fillPath()
        context.setFillColor(NSColor(srgbRed:22/255,green:133/255,blue:248/255,alpha:1).cgColor)
        for counter in SidebarWordmarkArtwork.counters { context.fillEllipse(in:counter) }
        context.restoreGState()
    }
}
