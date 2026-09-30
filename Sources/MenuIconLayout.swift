import AppKit

struct MenuIconLayout {
    let scale: CGFloat
    let origin: CGPoint
    static let ringDots: [CGPoint] = [126.0,102.0,78.0,54.0].map { degrees in
        let angle = degrees * .pi / 180
        return CGPoint(x:cos(angle)*100,y:sin(angle)*100)
    }
    static let ringSilhouette: CGPath = {
        let path = CGMutablePath()
        path.addArc(center:.zero,radius:100,startAngle:150 * .pi / 180,endAngle:390 * .pi / 180,clockwise:false)
        return path.copy(strokingWithWidth:17,lineCap:.round,lineJoin:.round,miterLimit:10)
    }()
    static let ringBounds = bounds(of:ringSilhouette,dots:ringDots,diameter:24)
    static let catBounds = bounds(of:DuoDuoCatGeometry.silhouette,dots:DuoDuoCatGeometry.resetDots,diameter:DuoDuoCatGeometry.dotDiameter)
    private static func bounds(of path:CGPath,dots:[CGPoint],diameter:CGFloat) -> CGRect {
        dots.reduce(path.boundingBoxOfPath) { bounds,point in
            bounds.union(CGRect(x:point.x-diameter/2,y:point.y-diameter/2,width:diameter,height:diameter))
        }
    }
    static func inRect(_ rect:CGRect,theme:MenuBarTheme) -> MenuIconLayout {
        // Match visible bounds, rather than unequal source canvases. Leave the
        // same breathing room above and below both themes in the menu bar.
        let height = min(rect.height*0.875,
                         rect.width*0.9/max(ringBounds.width/ringBounds.height,catBounds.width/catBounds.height))
        let bounds = theme == .duoDuoCat ? catBounds : ringBounds
        let scale = height/bounds.height
        return MenuIconLayout(scale:scale,origin:CGPoint(x:rect.midX-bounds.midX*scale,y:rect.midY-bounds.midY*scale))
    }
}
