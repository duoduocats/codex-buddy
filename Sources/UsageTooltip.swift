import SwiftUI

enum UsageTooltipPlacement {
    static func frame(contentSize:CGSize,anchor:CGPoint,bounds:CGRect,padding:CGFloat = 4) -> CGRect {
        let inset = min(max(0,padding),min(bounds.width,bounds.height)/2)
        let available = bounds.insetBy(dx:inset,dy:inset)
        let size = CGSize(width:min(max(0,contentSize.width),available.width),
                          height:min(max(0,contentSize.height),available.height))
        return CGRect(x:max(available.minX,min(anchor.x-size.width/2,available.maxX-size.width)),
                      y:max(available.minY,min(anchor.y,available.maxY-size.height)),
                      width:size.width,height:size.height)
    }
}

struct UsageTooltipLayout: Layout {
    var anchor: CGPoint
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        CGSize(width:proposal.width ?? 0,height:proposal.height ?? 0)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        guard let tooltip = subviews.first else { return }
        // Measure the localized label at the available width so long values wrap.
        let size = tooltip.sizeThatFits(ProposedViewSize(width:max(0,bounds.width-8),height:nil))
        let frame = UsageTooltipPlacement.frame(contentSize:size,
            anchor:CGPoint(x:bounds.minX+anchor.x,y:bounds.minY+anchor.y),bounds:bounds)
        tooltip.place(at:frame.origin,anchor:.topLeading,proposal:ProposedViewSize(frame.size))
    }
}
